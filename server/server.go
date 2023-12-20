package server

import (
	"context"
	"encoding/json"
	e "errors"
	"fmt"
	v1 "github.com/authzed/authzed-go/proto/authzed/api/v1"
	"github.com/authzed/authzed-go/v1"
	"github.com/jackc/pgx/v5"
	"github.com/lib/pq"
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

type InventoryHost struct {
	Id string
}

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

func getIdsFromInventoryHost(hosts []InventoryHost) []string {
	var ids []string
	for _, host := range hosts {
		ids = append(ids, host.Id)
	}
	return ids
}

func (c *PreFilterServer) GetContentPackagesWithDatabase(ctx context.Context, request api.GetContentPackagesRequestObject) (api.GetContentPackagesResponseObject, error) {
	ctx, span := c.Tracer.Start(ctx, "GetContentPackages")
	defer span.End()

	user, accountId, found := getIdentityFromContext(ctx)
	if found {
		fmt.Printf("indentity found in request: %s %d\n", user, accountId)
	}

	limit := limitHostIDs(ctx)

	inventoryHosts := make([]InventoryHost, 0)
	err := cachecontent.WithReadReplicaTx(func(tx *gorm.DB) error {
		result := tx.Raw("SELECT id FROM inventory.hosts LIMIT ?", limit).Scan(&inventoryHosts)
		if result.Error != nil {
			// Handle error
			fmt.Println(result.Error)
		}
		return nil
	})

	hostIDs := getIdsFromInventoryHost(inventoryHosts)

	_, pgSpan := c.Tracer.Start(ctx, "Postgres query")

	packageAccountData := make([]cachecontent.PackageAccountData, 0)

	var countError error
	if extractQueryOptimalization(ctx) == "cte" {
		countError = packagesByHostIDsCTE(&packageAccountData, accountId, hostIDs)
	} else if extractQueryOptimalization(ctx) == "temp-table" {
		countError = packagesByHostIDsTempTable(&packageAccountData, accountId, hostIDs)
	} else if extractQueryOptimalization(ctx) == "cte-temp-table" {
		countError = packagesByHostCTEinsteadOfTempTable(&packageAccountData, accountId, hostIDs)
	} else {
		countError = packagesByHostIDs(&packageAccountData, accountId, hostIDs)
	}

	if countError != nil {
		return nil, countError
	}

	packages, err := c.GetPackagesPayload(packageAccountData)

	pgSpan.End()

	return packages, err
}

func (c *PreFilterServer) GetContentPackages(ctx context.Context, request api.GetContentPackagesRequestObject) (api.GetContentPackagesResponseObject, error) {

	if databaseOnly(ctx) {
		return (*c).GetContentPackagesWithDatabase(ctx, request)
	}
	return (*c).GetContentPackagesWithSpiceDB(ctx, request)
}

func (c *PreFilterServer) GetContentPackagesWithSpiceDB(ctx context.Context, request api.GetContentPackagesRequestObject) (api.GetContentPackagesResponseObject, error) {
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

func limitHostIDs(ctx context.Context) string {
	limitHostIDsParam, ok := ctx.Value("Limit-Host-IDs").(string)
	if !ok {
		return "1"
	}

	return limitHostIDsParam
}
func databaseOnly(ctx context.Context) (found bool) {
	databaseOnlyFlag, ok := ctx.Value("Use-Database-Only").(string)
	if !ok {
		return false
	}

	return databaseOnlyFlag == "true"
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

func extractQueryOptimalization(ctx context.Context) string {
	optimalization, ok := ctx.Value("query-optimalization").(string)
	if !ok {
		return ""
	}

	return optimalization
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
			Where("ih.id IN ?", hostIDs).
			Group("sp.rh_account_id, spkg.name_id").
			Order("sp.rh_account_id, spkg.name_id")

		return q.Find(pkgSysCounts).Error
	})

	return errors.Wrap(err, "failed to get counts")
}

func packagesByHostIDsCTE(pkgSysCounts *[]cachecontent.PackageAccountData, accID int64, hostIDs []string) error {
	fmt.Printf("packagesByHostIDsCTE")

	err := cachecontent.WithReadReplicaTx(func(tx *gorm.DB) error {
		cteQuery := `
    WITH CTE_SystemUpdateStatus AS (
        SELECT
            sp.rh_account_id,
            spkg.name_id,
            spkg.update_data,
            update_status(spkg.update_data) as update_status
        FROM
            system_platform sp
            JOIN system_package spkg ON sp.id = spkg.system_id AND sp.rh_account_id = spkg.rh_account_id
            JOIN inventory.hosts ih ON sp.inventory_id = ih.id
        WHERE
            ih.id IN ?
    )
    SELECT
        s.rh_account_id,
        s.name_id,
        count(*) as systems_installed,
        count(*) filter (where s.update_status = 'Installable') as systems_installable,
        count(*) filter (where s.update_status != 'None') as systems_applicable
    FROM
        CTE_SystemUpdateStatus s
    GROUP BY
        s.rh_account_id, s.name_id
    ORDER BY
        s.rh_account_id, s.name_id
    `
		return tx.Raw(cteQuery, hostIDs).Scan(pkgSysCounts).Error
	})

	return errors.Wrap(err, "failed to get counts")
}

func packagesByHostIDsTempTable(pkgSysCounts *[]cachecontent.PackageAccountData, accID int64, hostIDs []string) error {
	fmt.Printf("packagesByHostIDsTempTable")

	err := cachecontent.WithReadReplicaTx(func(tx *gorm.DB) error {
		// Step 1: Create a temporary table
		if err := tx.Exec("CREATE TEMPORARY TABLE TempHostIDs (id UUID)").Error; err != nil {
			return err
		}

		// Step 2: Insert hostIDs into the temporary table
		for _, id := range hostIDs {
			if err := tx.Exec("INSERT INTO TempHostIDs (id) VALUES (?)", id).Error; err != nil {
				return err
			}
		}

		// Step 3: Modify the main query to join with the temporary table
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
			Joins("JOIN TempHostIDs th ON ih.id = th.id"). // Join with the temporary table
			Group("sp.rh_account_id, spkg.name_id").
			Order("sp.rh_account_id, spkg.name_id")

		// Execute the query
		if err := q.Find(pkgSysCounts).Error; err != nil {
			return err
		}

		// Optional: Drop the temporary table if needed
		return tx.Exec("DROP TABLE TempHostIDs").Error
	})

	return errors.Wrap(err, "failed to get counts")
}

func packagesByHostCTEinsteadOfTempTable(pkgSysCounts *[]cachecontent.PackageAccountData, accID int64, hostIDs []string) error {
	fmt.Printf("packagesByHostCTEinsteadOfTempTable")

	err := cachecontent.WithReadReplicaTx(func(tx *gorm.DB) error {
		// Define the CTE and main query
		cteAndQuery := `
			WITH HostIDCTE AS (
				 SELECT unnest(?::uuid[]) AS id  -- Convert the hostIDs slice to a set of rows
			)
			SELECT
				sp.rh_account_id rh_account_id,
				spkg.name_id package_name_id,
				count(*) as systems_installed,
				count(*) filter (where update_status(spkg.update_data) = 'Installable') as systems_installable,
				count(*) filter (where update_status(spkg.update_data) != 'None') as systems_applicable
			FROM
				system_platform sp
				JOIN system_package spkg ON sp.id = spkg.system_id AND sp.rh_account_id = spkg.rh_account_id
				JOIN rh_account acc ON sp.rh_account_id = acc.id
				JOIN inventory.hosts ih ON sp.inventory_id = ih.id
				JOIN HostIDCTE hcte ON ih.id = hcte.id
			GROUP BY
				sp.rh_account_id, spkg.name_id
			ORDER BY
				sp.rh_account_id, spkg.name_id
			`

		return tx.Raw(cteAndQuery, pq.Array(hostIDs)).Scan(pkgSysCounts).Error
	})

	return errors.Wrap(err, "failed to get counts")
}
