package main

import (
	"fmt"
	"github.com/merlante/inventory-access-poc/api"
	"net/http"
	"os"

	"github.com/merlante/inventory-access-poc/server"
)

var (
	spiceDBURL   = "localhost:50051"
	spiceDBToken = "foobar"
)

func main() {
	overwriteVarsFromEnv()

	spiceDbClient, err := server.GetSpiceDbClient(spiceDBURL, spiceDBToken)
	if err != nil {
		err := fmt.Errorf("%v", err)
		fmt.Println(err)
		os.Exit(1)
	}

	srv := server.ContentServer{
		SpicedbClient: spiceDbClient,
	}
	r := api.Handler(api.NewStrictHandler(&srv, nil))

	sErr := http.ListenAndServe(":8080", r)

	if sErr != nil {
		err := fmt.Errorf("error at server startup: %v", sErr)
		fmt.Println(err)
		os.Exit(1)
	}
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
