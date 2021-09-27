package gocd

import "context"

// PipelineGroupsService describes the HAL _link resource for the api response object for a pipeline group response.
type PipelineGroupsService service

// PipelineGroups represents a collection of pipeline groups
type PipelineGroups []*PipelineGroup

// PipelineGroup describes a pipeline group API response.
type PipelineGroup struct {
	Name      string      `json:"name"`
	Pipelines []*Pipeline `json:"pipelines"`
}

// List Pipeline groups
func (pgs *PipelineGroupsService) List(ctx context.Context, name string) (*PipelineGroups, *APIResponse, error) {

	apiVersion, err := pgs.client.getAPIVersion(ctx, "admin/pipeline_groups")
	if err != nil {
		return nil, nil, err
	}
	
	pg := []*PipelineGroup{}
	_, resp, err := pgs.client.getAction(ctx, &APIClientRequest{
		Path:         "admin/pipeline_groups" + name,
		APIVersion:   apiVersion,
		ResponseBody: pg,
	})

	return
}
