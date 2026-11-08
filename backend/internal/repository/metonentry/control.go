//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

const ExecutionReadFunction = "meton_ledger.read_text_execution(text,text,bigint,uuid,text,uuid)"
const ExecutionCancelFunction = "meton_ledger.cancel_original_text(text,text,bigint,uuid,text,uuid,jsonb)"

type originalExecutionControl struct{ read, cancel *sql.DB }

/** NewOriginalExecutionControl 只接受同一数据库的两个独立最小权限池，原生主连接不能代替。 */
func NewOriginalExecutionControl(read, cancel *sql.DB) (*service.MetonModelControl, error) {
	if read == nil || cancel == nil || read == cancel {
		return nil, service.ErrMetonClosed
	}
	identity, role, err := checkPool(read, ExecutionReadFunction)
	if err != nil {
		return nil, err
	}
	other, writer, err := checkPool(cancel, ExecutionCancelFunction)
	if err != nil || identity != other || role == writer {
		return nil, service.ErrMetonClosed
	}
	return service.NewMetonModelControl(&originalExecutionControl{read, cancel}), nil
}

/** OriginalExecution 单次语句就是原条件事务；网络异常不自动补写，随后由独立读身份核对。 */
func (s *originalExecutionControl) OriginalExecution(ctx context.Context, source service.MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID, expected *metonmodel.Admission) (json.RawMessage, error) {
	db, name := s.read, "meton_ledger.read_text_execution"
	params := []any{source.Environment, source.Source, source.Epoch, creation, caller, operation}
	arguments := "$1,$2,$3,$4,$5,$6"
	if expected != nil {
		db, name = s.cancel, "meton_ledger.cancel_original_text"
		raw, err := json.Marshal(expected)
		if err != nil {
			return nil, service.ErrMetonClosed
		}
		params = append(params, string(raw))
		arguments += ",$7"
	}
	var raw []byte
	err := db.QueryRowContext(ctx, "SELECT "+name+"("+arguments+")", params...).Scan(&raw)
	return raw, err
}
