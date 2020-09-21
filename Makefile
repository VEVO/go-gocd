# A few historical notes:
#
# * Why do we use stringer inside docker-compose?
#
#   On GoCD there is no AWS configuration on the agents so to get AWS credentials configured we need to use a
#   ephemeral docker volume where we build the AWS profile corresponding to the environment you want to use stringer
#   on as a 1st step. docker-compose is needed here to easily share those volumes.
#
#   Also, we don't want the stringer_build folder to be on the agents when you build in case some files you didn't want
#   don't get deleted so we create ephemeral docker volumes for that too and docker-compose is a really easy way to do that.
#
# * How can I simplify things?
#
#   The 1st thing you can do when wanting to simplify your Makefile is to get rid of all the targets that you will not need
#   (make sure that you keep the ones that your targets depend on).
#
#   Also, if you don't want any slack notifications, you can most likely get rid of all the `GO_*` variables except the
#   `GO_PIPELINE_NAME` which is used when building your image name.
#
#   Note that we use the `?=` syntax when assigning default values here so that it only takes this value if not set in
#   your environment.
#
# * What's the fuss about the `-p` flag of docker-compose?
#
#   When running docker-compose with volumes, the volumes are generated with the name that you provide. As those are the
#   same across projects eventually, we started to have configuration for 1 project being used by another project
#   because 2 jobs were running at the same time on an agent's instance (we can have more than 1 agent per instance
#   sharing the same docker engine) or because the project didn't cleanup its volumes before running its docker-compose
#   commands. That lead to a lot of problems.
#
#   Adding the `-p` followed by the project name tells docker to, internally, prefix the volume name (to create its id)
#   with the project name, same for its network interfaces. This way each project only accesses the volumes and network
#   interfaces that are prefixed by the project name, enhancing security but most importantly avoiding 2 builds to
#   overwrite each-other's configuration.

# setting some defaults if those variables are empty
GO_PIPELINE_NAME?=$(shell basename ${PWD})
CLUSTER?=services
OWNER=vevo
APP_NAME=$(GO_PIPELINE_NAME)
IMAGE_NAME=$(OWNER)/$(APP_NAME)
AWS_REGION?=us-east-1
AWS_PROFILE?=default
AWS_ACCOUNT?=$(AWS_PROFILE)
AWSCONFIG_VERSION?=1.0.2
STRINGER_VERSION?=latest
GO_REVISION?=$(shell git rev-parse HEAD)
GO_TO_REVISION?=$(GO_REVISION)
GO_FROM_REVISION?=$(shell git rev-parse refs/remotes/origin/master)
GIT_TAG=$(IMAGE_NAME):$(GO_REVISION)
BUILD_VERSION?=1.0.$(GO_PIPELINE_COUNTER)
BUILD_TAG=$(IMAGE_NAME):$(BUILD_VERSION)
LATEST_TAG=$(IMAGE_NAME):latest
# DOCKERFILE is a path related to resources/docker-compose.yaml
DOCKERFILE?=../Dockerfile

DC=GO_REVISION=$(GO_REVISION) GO_TO_REVISION=$(GO_TO_REVISION) GO_FROM_REVISION=$(GO_FROM_REVISION) DOCKERFILE=$(DOCKERFILE) BUILD_VERSION=$(BUILD_VERSION) CLUSTER=$(CLUSTER) AWS_REGION=$(AWS_REGION) AWS_PROFILE=$(AWS_PROFILE) AWS_ACCOUNT=$(AWS_ACCOUNT) GO_PIPELINE_NAME=$(GO_PIPELINE_NAME) AWSCONFIG_VERSION=$(AWSCONFIG_VERSION) STRINGER_VERSION=$(STRINGER_VERSION) docker-compose -p $(GO_PIPELINE_NAME) -f resources/docker-compose.yaml

# docker-lint runs an linter on your Dockerfile file using common best practices. Using it is optional but still
# recommended to avoid some common surprises.
docker-lint:
	$(DC) run --rm dockerlint

# docker-login authenticates you against the docker registry. It is necessary to be bable to pull private images like
# stringer and push your images. Chances are you don't need to do it locally as the docker authentication generates a
# token locally that can last a very long time. But on GoCD as the agents are docker containers and don't come
# pre-authenticated, it is safer to do a docker-login before the commands requiring a pull of private images or a push
# to the docker registry.
docker-login:
	@docker login -u "$(DOCKER_USER)" -p "$(DOCKER_PASS)"

# docker-build builds your docker image, providing the `BUILD_VERSION` as an argument. Handy if you want to be able to
# have your application know what version it runs (if you want it to tell you which one at least).
docker-build:
	docker build --build-arg BUILD_VERSION=$(BUILD_VERSION) -t $(GIT_TAG) .

# docker-tag generate tags for docker. By default the latest tag will be re-generated by you here to point to your last
# commit's `GIT_TAG` (which is the main tag you generate when usinmg docker-build). In addition to the `GIT_TAG` which is a
# git sha of the latest commit on which the image is build, we use also a more human-friendly `BUILD_TAG` which, by
# default is `1.0.<your_gocd_build_number>`. The latest and build tag are basically alias for the `GIT_TAG` to make it
# more human-readable so this make target is almost instantaneous after you ran `docker-build` successfully.
docker-tag:
	docker tag $(GIT_TAG) $(BUILD_TAG)
	docker tag $(GIT_TAG) $(LATEST_TAG)

# docker-push pushes the image with the 3 docker tags generated by docker-build and docker-tag to the docker registry.
docker-push: docker-login
	docker push $(GIT_TAG)
	docker push $(BUILD_TAG)
	docker push $(LATEST_TAG)

# dc-clean cleans previous docker-compose resources (volumes, network interfaces, etc) to avoid leftover between builds.
# It is a good practice to run it as a dependency of your 1st docker-compose command.
dc-clean:
	$(DC) down --rmi local --remove-orphans -v
	$(DC) rm -f -v

# dc-config generate the files necessary to have a fully functional setup based on your AWS_PROFILE and AWS_ACCOUNT. It
# is generated in a docker-compose volume to allow it to be shared with the other docker-compose services that would
# need it like stringer. Note that when running it locally on your computer, if your `~/.aws` folder is there, this
# target will use it. On GoCD it is generated using environment variables only.
dc-config: dc-clean
	$(DC) run --rm config

# kube-build allows you to generate the kubernetes configuration manifests based on the content of your
# stringer_spec/conf files and your stringer_spec/kubernetes files (if any). Note that this command is here so that you
# can test building locally but is generally not used in GoCD as it is already included in the kube-deploy target.
# The kubernetes cluster targeted by the build depends on the `AWS_PROFILE`, `AWS_ACCOUNT` and `CLUSTER` environment variables.
kube-build: dc-config
	$(DC) run --rm stringer build --tags kubernetes

# kube-deploy runs k8s-deployer which builds your kubernetes configuration, pushes it to your kubernetes cluster and
# wait for the rollout of the new version to be finished.
# The kubernetes cluster targeted by the deployment depends on the `AWS_PROFILE`, `AWS_ACCOUNT` and `CLUSTER` environment variables.
kube-deploy: dc-config
	# no build needed here as it is included in k8s-deployer
	$(DC) run --rm stringer k8s-deployer --extra-vars="_docker_image=$(BUILD_TAG)"

# terraform-build is used to generate the terraform configuration from the content of your stringer_spec/conf and
# stringer_spec/terraform.
# The kubernetes cluster targeted by the build depends on the `AWS_PROFILE`, `AWS_ACCOUNT` and `CLUSTER` environment variables.
terraform-build: dc-config
	$(DC) run --rm stringer build --tags terraform

# terraform-plan is used to generate the terraform plan based on the files generated by the terraform-build. Note that
# the terraform-build is automatically called when doing a `make terraform-plan`.
# The kubernetes cluster targeted by the build depends on the `AWS_PROFILE`, `AWS_ACCOUNT` and `CLUSTER` environment variables.
terraform-plan: terraform-build
	$(DC) run --rm stringer terraform plan

# terraform-apply will apply the terraform configuration planned in terraform-plan. Note that you need to run the
# terrafomr-plan target BEFORE running this target. This is not automatic and, as it modifies your resources, you should
# avoid making it automatic to have the time to review the changes you are about to make beforehand,
# The kubernetes cluster targeted by the build depends on the `AWS_PROFILE`, `AWS_ACCOUNT` and `CLUSTER` environment variables.
terraform-apply:
	$(DC) run --rm stringer terraform apply

# lambda-build is the target that is used to build lambda files. Note that the lambda are going away in a near future so
# we encourage you to avoid using them for new projects.
lambda-build: dc-config
	$(DC) run --rm stringer build --tags lambda

# slack_success generate a slack notification that shows a green status and potentially a changelog.
slack_success:
	$(DC) run --rm success

# slack_success generate a slack notification that shows a red status and potentially a changelog.
slack_failure:
	$(DC) run --rm failure

# build is the 1st step run by your GoCD pipeline and will build your docker image and push it to the docker registry.
build: docker-lint docker-build docker-tag docker-push

# dev is what is run for the dev stage of your pipeline and deploys your application to Kubernetes. Note that this does
# not include the terraform part yet as a lot of application don't require resources that terraform would provide.
dev: kube-deploy

# stg is what is run for the stg stage of your pipeline and doesn't do anything by default to give you time to test
# properly in dev. Note that by default, after a successful deployment in dev, this target will automatically be
# triggered.
stg:
	@echo "deploy staging something"

# prd is what  is run by the prd stage of your GoCD pipeline. By default it does nothing to give you more time to test
# in dev and stg. Note that this stage generally requires manual approval to be triggered in gocd.
prd:
	@echo "deploy prd something"

# vim: ft=make
