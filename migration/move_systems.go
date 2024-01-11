package migration

import (
	"context"
	"fmt"

	v1 "github.com/authzed/authzed-go/proto/authzed/api/v1"
	"github.com/authzed/authzed-go/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type MoveSystemsMigration struct {
	postgres *pgx.Conn
	spiceDb  *authzed.Client
}

func NewMoveSystemsMigration(postgres *pgx.Conn, spicedb *authzed.Client) *MoveSystemsMigration {
	return &MoveSystemsMigration{
		postgres: postgres,
		spiceDb:  spicedb,
	}
}

func (m *MoveSystemsMigration) MoveSystems(ctx context.Context, fromAccount int64, toAccount int64) error {
	rows, err := m.postgres.Query(ctx, "select ih.id as hostid from system_platform sp join inventory.hosts ih on sp.inventory_id = ih.id where sp.rh_account_id = $1;", fromAccount)
	if err != nil {
		return err
	}

	updates := make([]*v1.RelationshipUpdate, 0)

	fromWorkspace := &v1.SubjectReference{
		Object: &v1.ObjectReference{
			ObjectType: "workspace",
			ObjectId:   fmt.Sprintf("%d_root/ungrouped", fromAccount),
		},
	}

	toWorkspace := &v1.SubjectReference{
		Object: &v1.ObjectReference{
			ObjectType: "workspace",
			ObjectId:   fmt.Sprintf("%d_root/ungrouped", toAccount),
		},
	}

	for rows.Next() {
		values, err := rows.Values()
		if err != nil {
			return err
		}

		hostbytes := values[0].([16]byte)
		hostid, err := uuid.FromBytes(hostbytes[:])
		if err != nil {
			return err
		}
		host := &v1.ObjectReference{
			ObjectType: "inventory/host",
			ObjectId:   hostid.String(),
		}

		updates = append(updates, &v1.RelationshipUpdate{
			Operation: v1.RelationshipUpdate_OPERATION_DELETE,
			Relationship: &v1.Relationship{
				Resource: host,
				Relation: "workspace",
				Subject:  fromWorkspace,
			},
		})

		updates = append(updates, &v1.RelationshipUpdate{
			Operation: v1.RelationshipUpdate_OPERATION_TOUCH,
			Relationship: &v1.Relationship{
				Resource: host,
				Relation: "workspace",
				Subject:  toWorkspace,
			},
		})
	}

	tx, err := m.postgres.BeginTx(ctx, pgx.TxOptions{})
	m.postgres.Exec(ctx, "update system_platform set rh_account_id = $1 where rh_account_id = $2;", toAccount, fromAccount)
	_, err = m.spiceDb.WriteRelationships(ctx, &v1.WriteRelationshipsRequest{
		Updates: updates,
	})
	if err != nil {
		tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}
