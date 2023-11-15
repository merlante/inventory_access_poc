package main

import (
	"fmt"
	"github.com/merlante/prbac-spicedb/api"
	"net/http"
	"os"

	"github.com/merlante/prbac-spicedb/server"
)

var (
	spiceDBURL   = "localhost:50051"
	spiceDBToken = "foobar"
)

func main() {
	overwriteVarsFromEnv()

	spiceDbClient, err := server.GetSpiceDbClient(spiceDBURL, spiceDBToken)
	if err != nil {
		fmt.Errorf("%v", err)
		os.Exit(1)
	}

	server := server.ContentServer{
		SpicedbClient: spiceDbClient,
	}
	r := api.Handler(api.NewStrictHandler(&server, nil))

	http.ListenAndServe(":8080", r)
}

func overwriteVarsFromEnv() {
	envSpicedbUrl := os.Getenv("SPICEDB_URL")
	if envSpicedbUrl != "" {
		spiceDBURL = envSpicedbUrl
	}
	envSpicedbPsk := os.Getenv("SPICEDB_PSK")
	if envSpicedbPsk != "" {
		spiceDBToken = envSpicedbPsk
	}
}
