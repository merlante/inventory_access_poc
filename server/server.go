package server

import (
	"context"
	"github.com/authzed/authzed-go/v1"
	"github.com/jackc/pgx/v5"
	"github.com/merlante/inventory-access-poc/api"
)

type ContentServer struct {
	SpicedbClient *authzed.Client
	PostgresConn  *pgx.Conn
}

func (*ContentServer) GetContentPackages(ctx context.Context, request api.GetContentPackagesRequestObject) (api.GetContentPackagesResponseObject, error) {
	//TODO implement me
	panic("implement me")
}
