//go:build !meton_managed

package repository

import (
	"context"
	"database/sql"

	"github.com/Wei-Shaw/sub2api/internal/config"
)

/** 普通发行沿原生的迁移和初始化入口装配。 */
func verifyManagedDatabase(context.Context, *sql.DB, *config.Config) (bool, error) {
	return false, nil
}
