//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

/** 只使用独立控制池；原回执读取也是同一受限事务，提交失败不自动重试。 */
func (s *cashArchiveStore) RetryCashOriginal(ctx context.Context, q service.CashOriginalRetryCommand, action string) (json.RawMessage, error) {
	if s.control == nil {
		return nil, service.ErrMetonClosed
	}
	command, err := json.Marshal(q)
	if err != nil {
		return nil, err
	}
	tx, err := s.control.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var raw []byte
	if err = tx.QueryRowContext(ctx, "SELECT meton_inbox.cash_original_retry($1,$2,$3)", string(s.route), string(command), action).Scan(&raw); err != nil {
		return nil, err
	}
	// 在提交之前核对响应路由，不能把另一商户或恢复代次的成功当作本次调度。
	var current service.CashArchiveOriginalScope
	var reply struct {
		Scope *service.CashArchiveOriginalScope `json:"scope"`
	}
	if metonexecution.DecodeStrict(s.route, &current) != nil || json.Unmarshal(raw, &reply) != nil || reply.Scope != nil && *reply.Scope != current {
		return nil, service.ErrMetonClosed
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return raw, nil
}
