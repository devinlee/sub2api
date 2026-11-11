//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

/** openNoticeOriginIndex 只有显式配置才建立独立关联身份；既有资金消费者不自动取得索引权限。 */
func (w *purchaseWorker) openNoticeOriginIndex(ctx context.Context, base, path, sourceRole, deliveryRole string) error {
	if path == "" {
		return nil
	}
	data, err := readFile(base, path, 32768)
	if err != nil {
		return err
	}
	db, err := sql.Open("postgres", strings.TrimSpace(string(data)))
	if err != nil {
		return err
	}
	w.originIndex = db
	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)
	system, role, err := checkCashArchive(ctx, db, []string{
		"meton_inbox.lock_cash_notice_indexer(jsonb)", "meton_inbox.claim_cash_notice_origin(jsonb)",
		"meton_inbox.read_cash_notice_origin(jsonb,uuid,bytea,uuid)",
		"meton_inbox.finish_cash_notice_origin(jsonb,uuid,bytea,uuid,text,text,bytea)",
	})
	if err != nil || system != w.n.cfg.InboxSystem || role == sourceRole || role == deliveryRole {
		return service.ErrMetonClosed
	}
	_, err = db.ExecContext(ctx, "SELECT meton_inbox.lock_cash_notice_indexer($1)", string(w.n.wire))
	return err
}

/** indexNextNoticeOrigin 复用原密文及签名校验，只登记规范字节对应的原引用，不调用来源写入或重新派发现金。 */
func (w *purchaseWorker) indexNextNoticeOrigin(ctx context.Context) (bool, error) {
	if w.originIndex == nil {
		return false, nil
	}
	var claim purchaseClaim
	wire := string(w.n.wire)
	err := w.originIndex.QueryRowContext(ctx, "SELECT receipt_id,proof_hash,lease FROM meton_inbox.claim_cash_notice_origin($1)", wire).
		Scan(&claim.receipt, &claim.hash, &claim.lease)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	tx, err := w.originIndex.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return true, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return true, err
	}
	var kind, delivery, key string
	var sealed []byte
	// 未验真的结果必须传 SQL NULL；带类型的 nil []byte 可能被驱动编码为空 bytea，触发“意外规范字节”拒绝。
	var canonical any
	err = tx.QueryRowContext(ctx, "SELECT kind,delivery,key_ref,sealed FROM meton_inbox.read_cash_notice_origin($1,$2,$3,$4)",
		wire, claim.receipt, claim.hash, claim.lease).Scan(&kind, &delivery, &key, &sealed)
	if err != nil {
		return true, err
	}
	proof, failed := w.openProof(kind, delivery, key, claim.hash, sealed)
	outcome := purchaseOutcome{"indexed", "proof_verified"}
	if failed != nil {
		outcome = *failed
	} else {
		canonical = proof.basis
	}
	var saved bool
	err = tx.QueryRowContext(ctx, "SELECT meton_inbox.finish_cash_notice_origin($1,$2,$3,$4,$5,$6,$7)",
		wire, claim.receipt, claim.hash, claim.lease, outcome.state, outcome.reason, canonical).Scan(&saved)
	if err != nil {
		return true, err
	}
	if !saved {
		return true, service.ErrMetonClosed
	}
	return true, tx.Commit()
}
