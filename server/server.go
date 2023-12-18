package server

import (
	"context"
	"encoding/json"
	e "errors"
	"fmt"
	v1 "github.com/authzed/authzed-go/proto/authzed/api/v1"
	"github.com/authzed/authzed-go/v1"
	"github.com/jackc/pgx/v5"
	"github.com/merlante/inventory-access-poc/api"
	"github.com/merlante/inventory-access-poc/cachecontent"
	"github.com/pkg/errors"
	"go.opentelemetry.io/otel/trace"
	"gorm.io/gorm"
	"io"
	"net/http"
	"strconv"
	"strings"
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

	user, accountId, found := getIdentityFromContext(ctx)
	if found {
		fmt.Printf("indentity found in request: %s %d\n", user, accountId)
	}

	_, spiceSpan := c.Tracer.Start(ctx, "SpiceDB pre-filter call")

	lrClient, err := c.SpicedbClient.LookupResources(ctx, &v1.LookupResourcesRequest{
		ResourceObjectType: "inventory/host",
		Permission:         "read",
		Subject: &v1.SubjectReference{
			Object: &v1.ObjectReference{
				ObjectType: "user",
				ObjectId:   user,
			},
		},
	})

	if err != nil {
		fmt.Errorf("spicedb error: %v", err)
		return nil, err
	}

	var hostIDs []string
	for {
		next, err := lrClient.Recv()
		if e.Is(err, io.EOF) {
			break
		}
		if err != nil {
			fmt.Errorf("spicedb error: %v", err)
			return nil, err
		}

		hostIDs = append(hostIDs, next.GetResourceObjectId()) // e.g. service or inventory group
	}

	spiceSpan.End()

	_, pgSpan := c.Tracer.Start(ctx, "Postgres query")

	packageAccountData := make([]cachecontent.PackageAccountData, 0)
	countError := packagesByHostIDs(&packageAccountData, accountId, hostIDs)
	if countError != nil {
		return nil, countError
	}

	packages, err := c.GetPackagesPayload(packageAccountData)

	pgSpan.End()

	return packages, err
}

func getIdentityFromContext(ctx context.Context) (user string, rhAccount int64, found bool) {
	userInfo, ok := ctx.Value("user").(string)
	if !ok {
		// Handle case where the value is nil or not a string
		return "", 0, false
	}

	// Split the userInfo string to extract the user and rhAccount
	parts := strings.Split(userInfo, ";")
	if len(parts) != 2 {
		// Handle error if the format is not as expected
		return "", 0, false
	}

	// Assign the split values to user
	user = parts[0]

	// Convert the rhAccount part to int64
	var err error
	rhAccount, err = strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		// Handle error if the conversion fails
		return "", 0, false
	}

	return user, rhAccount, true
}

func packagesByHostIDs(pkgSysCounts *[]cachecontent.PackageAccountData, accID int64, hostIDs []string) error {
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
			Where("sp.rh_account_id = ?", accID).
			Where("ih.id IN ?", hostIDs).
			Group("sp.rh_account_id, spkg.name_id").
			Order("sp.rh_account_id, spkg.name_id")

		return q.Find(pkgSysCounts).Error
	})

	return errors.Wrap(err, "failed to get counts")
}
