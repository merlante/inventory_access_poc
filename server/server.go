package server

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/authzed/authzed-go/v1"
	"github.com/jackc/pgx/v5"
	"github.com/merlante/inventory-access-poc/api"
	"go.opentelemetry.io/otel/trace"
	"net/http"
	"time"
)

type Package struct {
	Name               string `json:"name"`
	Summary            string `json:"summary"`
	SystemsApplicable  int    `json:"systems_applicable"`
	SystemsInstallable int    `json:"systems_installable"`
	SystemsInstalled   int    `json:"systems_installed"`
}

type PackagesPayload struct {
	Data []Package `json:"data"`
}

func (p PackagesPayload) VisitGetContentPackagesResponse(w http.ResponseWriter) error {
	jsonResponse, err := json.Marshal(p)
	if err != nil {
		return err
	}

	w.Write(jsonResponse)
	if err != nil {
		return err
	}

	return nil
}

type PreFilterServer struct {
	Tracer        trace.Tracer
	SpicedbClient *authzed.Client
	PostgresConn  *pgx.Conn
}

func (c *PreFilterServer) GetPackagesPayload() (PackagesPayload, error) {
	q := `
		SELECT pn.name,
		       pn.summary,
		       res.systems_applicable,
		       res.systems_installable,
		       res.systems_installed
		FROM package_account_data res
		JOIN package_name pn ON res.package_name_id = pn.id;
	`
	rows, err := c.PostgresConn.Query(context.Background(), q)
	if err != nil {
		return PackagesPayload{}, fmt.Errorf("Failed to query packages: %w", err)
	}

	defer rows.Close()
	payload := PackagesPayload{}

	for rows.Next() {
		var p Package
		rows.Scan(&p.Name, &p.Summary, &p.SystemsApplicable, &p.SystemsInstallable, &p.SystemsInstalled)
		if err != nil {
			return PackagesPayload{}, fmt.Errorf("Failed to scan packages: %w", err)
		}
		payload.Data = append(payload.Data, p)
	}

	if rows.Err() != nil {
		return PackagesPayload{}, fmt.Errorf("Failed to iterate rows: %w", rows.Err())
	}

	return payload, nil
}

func (c *PreFilterServer) GetContentPackages(ctx context.Context, request api.GetContentPackagesRequestObject) (api.GetContentPackagesResponseObject, error) {
	ctx, span := c.Tracer.Start(ctx, "GetContentPackages")
	defer span.End()

	// TODO: user will be needed in spicedb queries -- set Authorization request header to the userid
	if user, found := getUserFromContext(ctx); found {
		fmt.Printf("user found in request: %s\n", user)
	}

	_, spiceSpan := c.Tracer.Start(ctx, "SpiceDB pre-filter call")
	time.Sleep(time.Second) // mimics the delay calling out to SpiceDB
	spiceSpan.End()

	_, pgSpan := c.Tracer.Start(ctx, "Postgres query")
	time.Sleep(time.Second) // mimics the delay calling out to Postgres
	pgSpan.End()

	packages, err := c.GetPackagesPayload()
	return packages, err
}

func getUserFromContext(ctx context.Context) (user string, found bool) {
	if user, ok := ctx.Value("user").(string); ok && user != "" {
		return user, true
	}

	return
}
