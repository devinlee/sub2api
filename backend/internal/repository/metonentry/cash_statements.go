//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

const CashStatementFunction = "meton_ledger.read_cash_statement(jsonb,jsonb,date,date,text,bigint,integer)"

/** 使用原只读池和新语句快照；没有来源缓存写入、补账或自动刷新后换页。 */
func (s *statementStore) CashStatement(ctx context.Context, source service.MetonManagedSource, q service.CashStatementRequest) (json.RawMessage, error) {
	if !source.ValidCashStatement(q) {
		return nil, service.ErrMetonClosed
	}
	origin, err := json.Marshal(q.Origin())
	if err != nil {
		return nil, err
	}
	audience, err := json.Marshal(q.Audience)
	if err != nil {
		return nil, err
	}
	tx, err := s.read.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var raw []byte
	if err = tx.QueryRowContext(ctx, "SELECT meton_ledger.read_cash_statement($1,$2,$3,$4,$5,$6,$7)", string(origin), string(audience), q.From, q.Through, q.Cut, q.After, q.Size).Scan(&raw); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return raw, nil
}
