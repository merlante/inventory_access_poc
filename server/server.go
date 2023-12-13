package server

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/authzed/authzed-go/v1"
	"github.com/jackc/pgx/v5"
	"github.com/merlante/inventory-access-poc/api"
	"github.com/merlante/inventory-access-poc/cachecontent"
	"github.com/pkg/errors"
	"go.opentelemetry.io/otel/trace"
	"gorm.io/gorm"
	"net/http"
	"time"
)

type PackagesPayload struct {
	Data []cachecontent.PackageAccountData `json:"data"`
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

func (c *PreFilterServer) GetPackagesPayload(acountData []cachecontent.PackageAccountData) (PackagesPayload, error) {
	payload := PackagesPayload{}
	for _, v := range acountData {
		payload.Data = append(payload.Data, v)
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

	account := 14
	hostIDs := []string{"0154aafc-0773-4ab7-bd5b-d018e9a85d1b", "08f3c261-9194-40db-bc48-963078a6ac12", "09854380-3a33-4446-bdf6-9e759942d681"}
	packageAccountData := make([]cachecontent.PackageAccountData, 0)
	countError := packagesByHostIDs(&packageAccountData, &account, hostIDs)
	if countError != nil {
		return nil, countError
	}

	packages, err := c.GetPackagesPayload(packageAccountData)

	pgSpan.End()

	return packages, err
}

func getUserFromContext(ctx context.Context) (user string, found bool) {
	if user, ok := ctx.Value("user").(string); ok && user != "" {
		return user, true
	}

	return
}

func packagesByHostIDs(pkgSysCounts *[]cachecontent.PackageAccountData, accID *int, hostIDs []string) error {
	err := cachecontent.WithReadReplicaTx(func(tx *gorm.DB) error {
		q := tx.Table("system_platform sp").
			Select(`
				sp.rh_account_id rh_account_id,
				spkg.name_id package_name_id,
				count(*) as systems_installed,
				count(*) filter (where update_status(spkg.update_data) = 'Installable') as systems_installable,
				count(*) filter (where update_status(spkg.update_data) != 'None') as systems_applicable
			`).
			Joins("JOIN system_package spkg ON sp.id = spkg.system_id AND sp.rh_account_id = spkg.rh_account_id").
			Joins("JOIN rh_account acc ON sp.rh_account_id = acc.id").
			Joins("JOIN inventory.hosts ih ON sp.inventory_id = ih.id").
			Where("sp.packages_installed > 0 AND sp.stale = FALSE").
			Where("ih.id IN ?", hostIDs).
			Group("sp.rh_account_id, spkg.name_id").
			Order("sp.rh_account_id, spkg.name_id")
		if accID != nil {
			q.Where("sp.rh_account_id = ?", *accID)
		} else {
			q.Where("acc.valid_package_cache = FALSE")
		}

		return q.Find(pkgSysCounts).Error
	})

	return errors.Wrap(err, "failed to get counts")
}
