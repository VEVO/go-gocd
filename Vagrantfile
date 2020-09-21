
$installGoCDScript = <<-SCRIPT
curl https://download.gocd.org/gocd.repo -o /etc/yum.repos.d/gocd.repo
yum update -y
yum install -y java-1.8.0-openjdk go-server git

systemctl enable go-server
systemctl start go-server
SCRIPT

Vagrant.configure("2") do |config|
  config.vm.box = "bento/centos-7"

  config.vm.provision "shell", inline: $installGoCDScript

  config.vm.network "forwarded_port", guest: 8154, host: 8154
  config.vm.network "forwarded_port", guest: 8153, host: 8153
end
