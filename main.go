package main

import (
	"context"
	"fmt"
	"net/http"
	"os"

	"github.com/merlante/inventory-access-poc/api"
	"github.com/merlante/inventory-access-poc/cachecontent"
	"github.com/merlante/inventory-access-poc/client"
	"github.com/merlante/inventory-access-poc/migration"

	"github.com/merlante/inventory-access-poc/server"
)

var (
	spiceDBURL   = "localhost:50051"
	spiceDBToken = "foobar"
	contentPgUri = "postgres://postgres:secret@content-postgres:5434/content?sslmode=disable"
)

func main() {
	overwriteVarsFromEnv()

	if os.Getenv("RUN_ACTION") == "REFRESH_PACKAGE_CACHES" {
		RefreshPackagesCaches()
	} else {
		initServer()
	}
}

func RefreshPackagesCaches() {
	cachecontent.Configure(contentPgUri)
	cachecontent.RefreshPackagesCaches(nil)
}

func initServer() {
	spiceDbClient, err := client.GetSpiceDbClient(spiceDBURL, spiceDBToken)
	if err != nil {
		err := fmt.Errorf("%v", err)
		fmt.Println(err)
		os.Exit(1)
	}

	pgConn, err := client.GetPostgresConnection(contentPgUri)
	if err != nil {
		err := fmt.Errorf("%v", err)
		fmt.Println(err)
		os.Exit(1)
	}
	defer pgConn.Close(context.Background())

	if os.Getenv("RUN_ACTION") == "MIGRATE_CONTENT_TO_SPICEDB" {
		fmt.Printf("Running migration from ContentDB to SpiceDB")
		migrator := migration.NewPSQLToSpiceDBMigration(pgConn, spiceDbClient)
		if err := migrator.MigrationContentDataToSpiceDb(context.TODO()); err != nil {
			panic(err)
		}
		return
	}

	srv := server.ContentServer{
		SpicedbClient: spiceDbClient,
		PostgresConn:  pgConn,
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

	envContentPgUri := os.Getenv("CONTENT_POSTGRES_URI")
	if envContentPgUri != "" {
		contentPgUri = envContentPgUri
	}
}
