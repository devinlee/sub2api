//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

const refundFinishSignature = "meton_ledger.http_finish_refund_cancel(text,text,bigint,timestamptz,bigint,text,jsonb)"
const refundStopSignature = "meton_inbox.stop_original_refund(jsonb,jsonb,text)"
const refundStopReadSignature = "meton_inbox.read_original_refund_stop(jsonb,jsonb,text)"

/** openRefundStopArchive 只装配停止用途，核对独立数据库系统编号和精确数据库角色。 */
func openRefundStopArchive(base string, cfg checkoutConfig, sourceRoles map[string]bool) (*sql.DB, error) {
	data, err := readFile(base, cfg.RefundStopArchiveDSN, 32768)
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	db, err := sql.Open("postgres", strings.TrimSpace(string(data)))
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	permissions := []string{refundStopSignature}
	var durableRead bool
	if err = db.QueryRowContext(ctx, "SELECT to_regprocedure($1) IS NOT NULL", refundStopReadSignature).Scan(&durableRead); err != nil {
		db.Close()
		return nil, service.ErrMetonClosed
	}
	if durableRead {
		permissions = append(permissions, refundStopReadSignature)
	}
	system, role, err := checkCashArchive(ctx, db, permissions)
	if err != nil || system != cfg.RefundStopSystem || sourceRoles[role] {
		db.Close()
		return nil, service.ErrMetonClosed
	}
	return db, nil
}

type refundStopMaterial struct {
	Current json.RawMessage `json:"current,omitempty"`
	Scope   json.RawMessage `json:"scope,omitempty"`
	Target  json.RawMessage `json:"target,omitempty"`
	Proof   string          `json:"originProof,omitempty"`
}

/** finishRefundStop 先在截点外封闭同笔外发，再在原账号事务释放。任何一次提交应答丢失都不能推定退款已取消。 */
func (p checkoutPool) finishRefundStop(ctx context.Context, tx *sql.Tx, raw string, wire []byte, access service.CheckoutAccess) (string, error) {
	var item refundStopMaterial
	if p.stopArchive == nil || metonexecution.DecodeStrict([]byte(raw), &item) != nil {
		return "", service.ErrMetonClosed
	}
	if len(item.Current) != 0 {
		if len(item.Scope) != 0 || len(item.Target) != 0 || item.Proof != "" {
			return "", service.ErrMetonClosed
		}
		return string(item.Current), nil
	}
	if len(item.Scope) == 0 || len(item.Target) == 0 || len(item.Proof) != 64 {
		return "", service.ErrMetonClosed
	}
	proof, err := p.committedRefundStop(ctx, item)
	if err != nil {
		return "", err
	}
	var result string
	err = tx.QueryRowContext(ctx, "SELECT meton_ledger.http_finish_refund_cancel($1,$2,$3,$4,$5,$6,$7)",
		string(wire), access.Key, access.Creator, access.Revision, access.UntilMS, access.Witness, string(proof)).Scan(&result)
	return result, err
}

/** committedRefundStop 只接受确定提交的停止或原票回执。新版独立库在第二个事务中才签名，查无时禁止补建。 */
func (p checkoutPool) committedRefundStop(ctx context.Context, item refundStopMaterial) ([]byte, error) {
	statements := [...]string{"SELECT meton_inbox.stop_original_refund($1,$2,$3)", "SELECT meton_inbox.read_original_refund_stop($1,$2,$3)"}
	for _, statement := range statements {
		archive, err := p.stopArchive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
		if err != nil {
			return nil, service.ErrMetonClosed
		}
		var proof []byte
		if _, err = archive.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err == nil {
			err = archive.QueryRowContext(ctx, statement, string(item.Scope), string(item.Target), item.Proof).Scan(&proof)
		}
		if err != nil {
			archive.Rollback()
			return nil, service.ErrMetonClosed
		}
		if err = archive.Commit(); err != nil {
			return nil, service.ErrMetonClosed
		}
		var signed struct {
			MAC *string `json:"mac"`
		}
		if json.Unmarshal(proof, &signed) != nil {
			return nil, service.ErrMetonClosed
		}
		if signed.MAC != nil {
			if len(*signed.MAC) != 64 {
				return nil, service.ErrMetonClosed
			}
			return proof, nil
		}
	}
	return nil, service.ErrMetonClosed
}
