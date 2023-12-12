package server

import (
	"context"
	"database/sql"
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
	NameId          int64         `json:"name_id"`
	Evra            string        `json:"evra"`
	DescriptionHash []byte        `json:"description_hash"`
	SummaryHash     []byte        `json:"summary_hash"`
	AdvisoryId      sql.NullInt64 `json:"advisory_id"`
	Synced          bool          `json:"synced"`
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
	rows, err := c.PostgresConn.Query(context.Background(), "SELECT name_id, evra, description_hash, summary_hash, advisory_id, synced synced FROM package;")
	if err != nil {
		return PackagesPayload{}, fmt.Errorf("Failed to query packages: %w", err)
	}

	defer rows.Close()
	payload := PackagesPayload{}

	for rows.Next() {
		var p Package
		rows.Scan(&p.NameId, &p.Evra, &p.DescriptionHash, &p.SummaryHash, &p.AdvisoryId, &p.Synced)
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

	_, spiceSpan := c.Tracer.Start(ctx, "SpiceDB pre-filter call")
	time.Sleep(time.Second) // mimics the delay calling out to SpiceDB
	spiceSpan.End()

	_, pgSpan := c.Tracer.Start(ctx, "Postgres query")
	time.Sleep(time.Second) // mimics the delay calling out to Postgres
	pgSpan.End()

	packages, err := c.GetPackagesPayload()
	return packages, err
}
