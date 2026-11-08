package service

import (
	"context"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/google/uuid"
)

type MetonModelResultStore interface {
	OriginalModelResult(context.Context, MetonManagedSource, uuid.UUID, string, uuid.UUID) (json.RawMessage, error)
}

/** OriginalModelResult 复用独立查询许可，不能通过查询结算、续期或发送模型请求。 */
func (s *adminServiceImpl) OriginalModelResult(ctx context.Context, source MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID) (json.RawMessage, error) {
	live, available := MetonSource()
	_, readable := source.ModelReadID()
	repo, ok := s.userRepo.(MetonModelResultStore)
	if !available || !readable || live != source || !ok || creation == uuid.Nil || operation == uuid.Nil || (caller != "meton.chat.v1" && caller != "meton.oc07.v1") {
		return nil, ErrMetonClosed
	}
	raw, err := repo.OriginalModelResult(ctx, source, creation, caller, operation)
	if err != nil {
		return nil, ErrMetonClosed
	}
	if len(raw) == 0 {
		return nil, nil
	}
	result, err := metonmodel.ReadResult(raw)
	if err != nil || result.Admission.AcceptedEpoch > source.Epoch || result.Admission.Origin.Environment != source.Environment ||
		result.Admission.Origin.Source != source.Source || result.Admission.Origin.Caller != caller || result.Admission.Origin.OperationID != operation.String() {
		return nil, ErrMetonClosed
	}
	if current, ok := MetonSource(); !ok || current != source {
		return nil, ErrMetonClosed
	}
	return json.Marshal(result)
}
