package repository

import (
	"context"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

/** OriginalModel 只有一条受限查询语句，不借用预占、扣款或发送身份。当前来源栅栏由原账本查询复验。 */
func (r *userRepository) OriginalModel(ctx context.Context, s service.MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID, event *uuid.UUID) (json.RawMessage, error) {
	if r.sql == nil {
		return nil, service.ErrMetonClosed
	}
	rows, err := r.sql.QueryContext(ctx, "SELECT meton_ledger.read_text_reference($1,$2,$3,$4,$5,$6,$7)", s.Environment, s.Source, s.Epoch, creation, caller, operation, event)
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
