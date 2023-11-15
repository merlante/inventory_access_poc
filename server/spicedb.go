package server

import (
	"github.com/authzed/authzed-go/v1"
	"github.com/authzed/grpcutil"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func GetSpiceDbClient(endpoint string, presharedKey string) (*authzed.Client, error) {
	var opts []grpc.DialOption

	opts = append(opts, grpc.WithBlock())

	opts = append(opts, grpcutil.WithInsecureBearerToken(presharedKey))
	opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))

	return authzed.NewClient(
		endpoint,
		opts...,
	)
}
