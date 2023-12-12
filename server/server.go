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

type PackageName struct {
	Name    string `json:"name"`
	Summary string `json:"summary"`
}

type Package struct {
	NameId          int    `json:"name_id"`
	Evra            string `json:"evra"`
	DescriptionHash string `json:"description_hash"`
	SummaryHash     string `json:"summary_hash"`
	AdvisoryId      int    `json:"advisory_id"`
	Synced          bool   `json:"synced"`
}

type PackagePayload struct {
	Packages []Package `json:"packages"`
}

func (p PackagePayload) VisitGetContentPackagesResponse(w http.ResponseWriter) error {
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

func (c *PreFilterServer) QueryPackages() (PackagePayload, error) {
	rows, err := c.PostgresConn.Query(context.Background(), "SELECT name_id, evra, synced FROM package;")
	if err != nil {
		return PackagePayload{}, fmt.Errorf("Failed to query packages: %w", err)
	}

	defer rows.Close()
	ps := PackagePayload{}

	for rows.Next() {
		var p Package
		rows.Scan(&p.NameId, &p.Evra, &p.Synced)
		if err != nil {
			return PackagePayload{}, fmt.Errorf("Failed to scan packages: %w", err)
		}
		ps.Packages = append(ps.Packages, p)
	}

	if rows.Err() != nil {
		return PackagePayload{}, fmt.Errorf("Failed to iterate rows: %w", rows.Err())
	}

	return ps, nil
}

func (c *PreFilterServer) GetContentPackages(ctx context.Context, request api.GetContentPackagesRequestObject) (api.GetContentPackagesResponseObject, error) {
	ctx, span := c.Tracer.Start(ctx, "GetContentPackages")
	defer span.End()

	_, spiceSpan := c.Tracer.Start(ctx, "SpiceDB pre-filter call")
	time.Sleep(time.Second) // mimics the delay calling out to SpiceDB
	spiceSpan.End()

	_, pgSpan := c.Tracer.Start(ctx, "Postgres query")
	time.Sleep(time.Second) // mimics the delay calling out to Postgres
	pgSpan.End()

	packages, err := c.QueryPackages()
	return packages, err
}
