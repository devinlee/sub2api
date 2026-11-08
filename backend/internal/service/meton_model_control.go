package service

import (
	"context"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/google/uuid"
	"os"
)

// MetonModelControlStore 只观察原发送裁决或尝试同事务取消；没有创建请求、派发、扣费或更换 Key 的能力。
type MetonModelControlStore interface {
	OriginalExecution(context.Context, MetonManagedSource, uuid.UUID, string, uuid.UUID, *metonmodel.Admission) (json.RawMessage, error)
}
type MetonModelControl struct{ store MetonModelControlStore }

/** NewMetonModelControl 由来源装配方注入独立的只读和取消连接，不借用原生账户仓储。 */
func NewMetonModelControl(store MetonModelControlStore) *MetonModelControl {
	if store == nil {
		return nil
	}
	return &MetonModelControl{store: store}
}

/** ModelCancelID 不继承查询、发放或会话权限；缺独立身份时取消入口保持关闭。 */
func (s MetonManagedSource) ModelCancelID() (string, bool) {
	id := os.Getenv("METON_MANAGED_MODEL_CANCEL_KEY_ID")
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || !metonKeyID.MatchString(id) || id == s.CreateKeyID || id == s.ReadKeyID {
		return "", false
	}
	for _, name := range []string{"FUNDS_READ", "ISSUE", "INSPECT", "ROTATE", "CLOSE", "GRANT_WRITE", "GRANT_READ", "MODEL_READ"} {
		if id == os.Getenv("METON_MANAGED_"+name+"_KEY_ID") {
			return "", false
		}
	}
	return id, true
}

/** Execute 回应丢失保留未知，不重试写入；当前来源变化时不发布旧回执。 */
func (s *MetonModelControl) Execute(ctx context.Context, source MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID, request *metonmodel.Cancellation) (json.RawMessage, error) {
	cancel := request != nil
	live, available := MetonSource()
	_, allowed := source.ModelReadID()
	if cancel {
		_, allowed = source.ModelCancelID()
	}
	if s == nil || s.store == nil || !available || live != source || !allowed || creation == uuid.Nil || operation == uuid.Nil ||
		(caller != "meton.chat.v1" && caller != "meton.oc07.v1") {
		return nil, ErrMetonClosed
	}
	var expected *metonmodel.Admission
	if request != nil {
		encoded, _ := json.Marshal(request)
		verified, err := metonmodel.ReadCancellation(encoded)
		if err != nil || verified.Epoch != source.Epoch || verified.Admission.Origin.Environment != source.Environment ||
			verified.Admission.Origin.Source != source.Source || verified.Admission.Origin.Caller != caller || verified.Admission.Origin.OperationID != operation.String() {
			return nil, ErrMetonClosed
		}
		expected = &verified.Admission
	}
	raw, err := s.store.OriginalExecution(ctx, source, creation, caller, operation, expected)
	if err != nil {
		return nil, ErrMetonClosed
	}
	if len(raw) == 0 {
		return nil, nil
	}
	result, err := metonmodel.ReadExecution(raw)
	if err != nil || result.Admission.AcceptedEpoch > source.Epoch || cancel && result.Admission.AcceptedEpoch != source.Epoch ||
		result.Admission.Origin.Environment != source.Environment || result.Admission.Origin.Source != source.Source ||
		result.Admission.Origin.Caller != caller || result.Admission.Origin.OperationID != operation.String() {
		return nil, ErrMetonClosed
	}
	if current, ok := MetonSource(); !ok || current != source {
		return nil, ErrMetonClosed
	}
	if expected != nil {
		want, _ := json.Marshal(expected)
		got, _ := json.Marshal(result.Admission)
		if string(want) != string(got) {
			return nil, ErrMetonClosed
		}
	}
	return json.Marshal(result)
}
