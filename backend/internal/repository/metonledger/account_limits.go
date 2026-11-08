//go:build meton_managed

package metonledger

import (
	"context"
	"database/sql"
	"errors"
)

/** 新版本不能在漏装或停用账户限制的旧结构上继续受理；来源模式切换和维护仍由原恢复屏障裁决。 */
func requireAccountLimit(ctx context.Context, conn *sql.Conn) error {
	var ready bool
	err := conn.QueryRowContext(ctx, `SELECT EXISTS (
		SELECT FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
		WHERE t.tgrelid=to_regclass('meton_ledger.text_requests') AND t.tgname='enforce_text_account_limit'
		  AND t.tgfoid=to_regprocedure('meton_ledger.enforce_text_account_limit()')
		  AND t.tgenabled IN ('O','A') AND t.tgtype=7 AND NOT t.tgisinternal
		  AND t.tgqual IS NULL AND t.tgnargs=0 AND p.prosecdef AND p.pronargs=0
	)`).Scan(&ready)
	if err != nil {
		return err
	}
	if !ready {
		return errors.New("managed account admission guard unavailable")
	}
	return nil
}
