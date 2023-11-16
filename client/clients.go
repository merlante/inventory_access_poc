package client

import (
	"context"
	"fmt"
	"github.com/authzed/authzed-go/v1"
	"github.com/authzed/grpcutil"
	"github.com/jackc/pgx/v5"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"os"
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

func GetPostgresConnection(connUri string) (*pgx.Conn, error) {
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, connUri)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Unable to connect to database: %v\n", err)
		return nil, err
	}
	err = conn.Ping(ctx)

	if err == nil {
		fmt.Println("Connection to content postgres established")
	} else {
		fmt.Fprintf(os.Stderr, "Couldn't ping content postgres: %v\n", err)
	}

	return conn, nil
}
