package main

import (
	"context"
	"errors"
	"fmt"
	"github.com/merlante/inventory-access-poc/opentelemetry"
	"go.opentelemetry.io/otel"
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
	cachecontent.Configure(contentPgUri)

	otelShutdown, err := initOpenTelemetry()
	defer func() {
		err = errors.Join(err, otelShutdown(context.Background()))
	}()

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
		if err := migrator.MigrateContentHostsAndSystemsToSpiceDb(context.TODO()); err != nil {
			panic(err)
		}
		return
	}
	if os.Getenv("RUN_ACTION") == "MIGRATE_PACKAGES_TO_SPICEDB" {
		fmt.Printf("Running migration of packages from ContentDB to SpiceDB")
		migrator := migration.NewPSQLToSpiceDBMigration(pgConn, spiceDbClient)
		if err := migrator.MigratePackages(context.TODO()); err != nil {
			panic(err)
		}
		return
	}

	tracer := otel.Tracer("HttpServer")

	pfSrv := server.PreFilterServer{
		Tracer:        tracer,
		SpicedbClient: spiceDbClient,
		PostgresConn:  pgConn,
	}

	preFilterHandler := api.Handler(api.NewStrictHandler(&pfSrv, nil))

	experimentHandlers := map[string]http.Handler{
		"pre-filter": preFilterHandler,
	}

	h := getExperimentsHandler(&experimentHandlers)
	h = extractUserMiddleware(h)

	sErr := http.ListenAndServe(":8080", h)

	if sErr != nil {
		err := fmt.Errorf("error at server startup: %v", sErr)
		fmt.Println(err)
		os.Exit(1)
	}
}

func extractUserMiddleware(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user := r.Header.Get("Authorization")

		if user != "" {
			ctx := context.WithValue(r.Context(), "user", user)
			h.ServeHTTP(w, r.WithContext(ctx))
			return
		}

		h.ServeHTTP(w, r)
	})
}

// a mechanism for using request headers as a router for selecting the correct experiment/server implementation
func getExperimentsHandler(handlerMap *map[string]http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		experiment := r.Header.Get("Experiment")
		if experiment == "" {
			experiment = "pre-filter"
		}

		h, found := (*handlerMap)[experiment]
		if !found {
			err := fmt.Errorf("error: no handler registered for Experiment %s specified in request header", experiment)
			fmt.Println(err)
			return
		}

		h.ServeHTTP(w, r)
	})
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

func initOpenTelemetry() (shutdown func(context.Context) error, err error) {
	// Set up OpenTelemetry.
	serviceName := "inventory_access_poc"
	serviceVersion := "0.1.0"
	shutdown, err = opentelemetry.SetupOTelSDK(context.TODO(), serviceName, serviceVersion)

	return
}
