package repository

import (
	"context"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

/** OriginalModelResult 以只读身份取同一原请求的事实，不接受或生成新的费用 ID。 */
func (r *userRepository) OriginalModelResult(ctx context.Context, s service.MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID) (json.RawMessage, error) {
	if r.sql == nil {
		return nil, service.ErrMetonClosed
	}
	rows, err := r.sql.QueryContext(ctx, "SELECT meton_ledger.read_text_result($1,$2,$3,$4,$5,$6)", s.Environment, s.Source, s.Epoch, creation, caller, operation)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	var raw []byte
	if err = rows.Scan(&raw); err != nil {
		return nil, err
	}
	if rows.Next() || rows.Err() != nil {
		return nil, service.ErrMetonClosed
	}
	return raw, nil
}
