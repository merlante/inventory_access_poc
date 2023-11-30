package cachecontent

import (
	"github.com/pkg/errors"
	"gorm.io/gorm"
)

// return database handler with base context
// which will be properly cancled in case of service shutdown
func CancelableDB() *gorm.DB {
	return Db.WithContext(Context)
}

func CancelableReadReplicaDB() *gorm.DB {
	return Db.WithContext(Context)
}

func withTx(do func(db *gorm.DB) error, cancelableDB func() *gorm.DB) error {
	tx := cancelableDB().Begin()
	defer tx.Rollback()
	if err := do(tx); err != nil {
		return err
	}
	return errors.Wrap(tx.Commit().Error, "Commit")
}

// Need to run code within a function, because defer can't be used in loops
func WithTx(do func(db *gorm.DB) error) error {
	return withTx(do, CancelableDB)
}

// Need to run code within a function, because defer can't be used in loops
func WithReadReplicaTx(do func(db *gorm.DB) error) error {
	return withTx(do, CancelableReadReplicaDB)
}
