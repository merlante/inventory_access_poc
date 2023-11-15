package server

import (
	"context"
	"github.com/authzed/authzed-go/v1"
	"github.com/merlante/prbac-spicedb/api"
)

type ContentServer struct {
	SpicedbClient *authzed.Client
}

func (*ContentServer) GetContentPackages(ctx context.Context, request api.GetContentPackagesRequestObject) (api.GetContentPackagesResponseObject, error) {
	//TODO implement me
	panic("implement me")
}
