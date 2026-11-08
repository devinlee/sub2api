//go:build meton_managed

package repository

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/migrations"
)

/** 已有费用来源的运行进程只验证受控部署的结构和秘密。所有检查共享一个只读快照。 */
func verifyManagedDatabase(ctx context.Context, db *sql.DB, cfg *config.Config) (bool, error) {
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" {
		return false, nil
	}
	if cfg.RunMode != config.RunModeStandard {
		return true, errors.New("managed funded runtime requires standard mode")
	}
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true})
	if err != nil {
		return true, err
	}
	defer tx.Rollback()
	// 业务身份不能改原生余额、来源事件、数据库结构或校验记录。
	var limited bool
	err = tx.QueryRowContext(ctx, `SELECT NOT r.rolsuper AND NOT r.rolcreaterole AND NOT r.rolcreatedb
		AND NOT r.rolreplication AND NOT r.rolbypassrls
		AND NOT has_database_privilege(current_user,current_database(),'CREATE')
		AND NOT has_schema_privilege(current_user,'public','CREATE')
		AND NOT has_schema_privilege(current_user,'meton_ledger','CREATE')
		AND NOT has_column_privilege(current_user,'public.users','balance','UPDATE,INSERT')
		AND NOT has_column_privilege(current_user,'public.users','frozen_balance','UPDATE,INSERT')
		AND NOT has_column_privilege(current_user,'public.users','total_recharged','UPDATE,INSERT')
		AND NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
			WHERE c.relkind IN ('r','p') AND (n.nspname='meton_ledger' OR n.nspname='public'
			AND c.relname IN ('schema_migrations','atlas_schema_revisions','security_secrets','meton_managed_fence'))
			AND (has_table_privilege(current_user,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER')
			OR has_any_column_privilege(current_user,c.oid,'INSERT,UPDATE')))
		FROM pg_roles r WHERE r.rolname=current_user`).Scan(&limited)
	if err != nil {
		return true, err
	}
	if !limited {
		return true, errors.New("managed funded runtime has deployment or raw financial privileges")
	}
	if err = verifyManagedNativeHistory(ctx, tx, migrations.FS); err != nil {
		return true, err
	}
	// 已有实例必须由部署方提供当前秘密。缺失和恢复后的不匹配不能触发自动生成或采用旧库的值。
	var persisted string
	if err = tx.QueryRowContext(ctx, "SELECT value FROM public.security_secrets WHERE key='jwt_secret'").Scan(&persisted); err != nil {
		return true, err
	}
	if len(cfg.JWT.Secret) < 32 || subtle.ConstantTimeCompare([]byte(cfg.JWT.Secret), []byte(persisted)) != 1 {
		return true, errors.New("managed deployment secret does not match")
	}
	return true, tx.Commit()
}

/** 只接受嵌入的原生迁移和可核对的 Atlas 基线；托管迁移仍由独立部署身份安装。 */
func verifyManagedNativeHistory(ctx context.Context, tx *sql.Tx, source fs.FS) error {
	files, err := fs.Glob(source, "*.sql")
	if err != nil {
		return err
	}
	expected := make(map[string]string, len(files))
	for _, name := range files {
		content, err := fs.ReadFile(source, name)
		if err != nil {
			return err
		}
		sqlText := strings.TrimSpace(string(content))
		if sqlText != "" {
			sum := sha256.Sum256([]byte(sqlText))
			expected[name] = hex.EncodeToString(sum[:])
		}
	}
	var baselines, matching int
	var version, hash string
	err = tx.QueryRowContext(ctx, `SELECT count(*),count(*) FILTER (WHERE type=1 AND applied=0 AND total=0
		AND description=version AND error IS NULL AND error_stmt IS NULL),coalesce(min(version),''),coalesce(min(hash),'')
		FROM public.atlas_schema_revisions`).Scan(&baselines, &matching, &version, &hash)
	if err != nil {
		return err
	}
	if baselines != 1 || matching != 1 || hash == "" || expected[version+".sql"] != hash {
		return errors.New("managed native Atlas baseline mismatch")
	}
	rows, err := tx.QueryContext(ctx, "SELECT filename,checksum FROM public.schema_migrations")
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var name, checksum string
		if err := rows.Scan(&name, &checksum); err != nil {
			return err
		}
		if want, ok := expected[name]; !ok || want != checksum {
			return errors.New("managed native migration history mismatch")
		}
		delete(expected, name)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if len(expected) != 0 {
		return errors.New("managed native migration history is incomplete")
	}
	return nil
}
