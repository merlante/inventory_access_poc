package migration

import (
	"context"
	"fmt"
	"strconv"

	v1 "github.com/authzed/authzed-go/proto/authzed/api/v1"
	"github.com/authzed/authzed-go/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const maxRelationshpBatchSize = 100

type PSQLToSpiceDBMigration struct {
	postgres     *pgx.Conn
	spiceDb      *authzed.Client
	orgUngrouped map[int32]string
	context      context.Context
	updates      []*v1.RelationshipUpdate
}

func NewPSQLToSpiceDBMigration(postgres *pgx.Conn, spiceDb *authzed.Client) *PSQLToSpiceDBMigration {
	return &PSQLToSpiceDBMigration{
		postgres:     postgres,
		spiceDb:      spiceDb,
		orgUngrouped: map[int32]string{},
		updates:      make([]*v1.RelationshipUpdate, 0, maxRelationshpBatchSize),
	}
}

func (m *PSQLToSpiceDBMigration) MigratePackages(ctx context.Context) error {
	m.context = ctx
	rows, err := m.postgres.Query(ctx, "select name_id, system_id from system_package;")
	if err != nil {
		return err
	}

	count := 0

	for rows.Next() {
		values, err := rows.Values()
		if err != nil {
			return err
		}

		nameId := values[0].(int64)
		systemId := values[1].(int64)

		if err = m.addUpdate("patch/patch", strconv.FormatInt(nameId, 10), "system", "patch/system", strconv.FormatInt(systemId, 10)); err != nil {
			return err
		}

		count++
		if count%1_000 == 0 {
			fmt.Printf("\rProcessed %d system patches.", count)
		}
	}

	fmt.Println()
	return m.flushUpdates()
}

func (m *PSQLToSpiceDBMigration) MigrateContentHostsAndSystemsToSpiceDb(ctx context.Context) error {
	m.context = ctx
	rows, err := m.postgres.Query(ctx, "select sp.id AS systemid, ih.id AS hostid, sp.rh_account_id from system_platform sp JOIN inventory.hosts ih ON sp.inventory_id = ih.id")
	if err != nil {
		return err
	}

	count := 0

	for rows.Next() {
		values, err := rows.Values()
		if err != nil {
			return err
		}

		systemId := values[0].(int64)

		hostbytes := values[1].([16]byte)
		hostid, err := uuid.FromBytes(hostbytes[:])
		if err != nil {
			return err
		}

		orgId := values[2].(int32)

		ungrouped, match := m.orgUngrouped[orgId]
		if !match {
			root := fmt.Sprintf("%d_root", orgId)
			ungrouped = fmt.Sprintf("%s/ungrouped", root)

			if err = m.addUpdate("workspace", root, "parent", "organization", strconv.FormatInt(int64(orgId), 10)); err != nil {
				return err
			}

			if err = m.addUpdate("workspace", ungrouped, "parent", "workspace", root); err != nil {
				return err
			}

			m.orgUngrouped[orgId] = ungrouped
		}

		host := hostid.String()
		if err = m.addUpdate("inventory/host", host, "workspace", "workspace", ungrouped); err != nil {
			return err
		}

		if err = m.addUpdate("patch/system", strconv.FormatInt(systemId, 10), "host", "inventory/host", host); err != nil {
			return err
		}

		count++
		if count%1 == 0 {
			fmt.Printf("\rProcessed %d hosts.\n", count)
		}
	}

	return m.flushUpdates()
}

func (m *PSQLToSpiceDBMigration) addUpdate(resourceType string, resourceId string, relationship string, subjectType string, subjectId string) error {
	if len(m.updates) >= maxRelationshpBatchSize {
		err := m.flushUpdates()
		if err != nil {
			return err
		}
	}

	update := &v1.RelationshipUpdate{
		Operation: v1.RelationshipUpdate_OPERATION_TOUCH,
		Relationship: &v1.Relationship{
			Resource: &v1.ObjectReference{
				ObjectType: resourceType,
				ObjectId:   resourceId,
			},
			Relation: relationship,
			Subject: &v1.SubjectReference{
				Object: &v1.ObjectReference{
					ObjectType: subjectType,
					ObjectId:   subjectId,
				},
			},
		},
	}

	m.updates = append(m.updates, update)
	return nil
}

func (m *PSQLToSpiceDBMigration) flushUpdates() error {
	_, err := m.spiceDb.WriteRelationships(m.context, &v1.WriteRelationshipsRequest{
		Updates: m.updates,
	})

	m.updates = m.updates[:0]

	return err
}
