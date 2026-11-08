package service

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/google/uuid"
)

type MetonResultControlStore interface {
	Reconcile(context.Context, MetonManagedSource, uuid.UUID, string, metonmodel.ReconciliationRequest, func(context.Context) error) (json.RawMessage, error)
}

type MetonResultControl struct{ store MetonResultControlStore }

/** ResultControlID 三种新身份必须完整、互斥，且不能兼任任何已有托管服务身份。 */
func (s MetonManagedSource) ResultControlID(action string) (string, bool) {
	purpose := map[string]string{"observe": "RESULT_OBSERVE", "proof": "RESULT_READ", "apply": "RESULT_APPLY", "resolution": "RESULT_READ"}[action]
	if purpose == "" || os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" {
		return "", false
	}
	seen := map[string]bool{}
	for _, name := range []string{"RESULT_OBSERVE", "RESULT_READ", "RESULT_APPLY"} {
		key := "METON_MANAGED_" + name + "_KEY_ID"
		id := os.Getenv(key)
		if !metonKeyID.MatchString(id) || seen[id] || id == s.CreateKeyID || id == s.ReadKeyID {
			return "", false
		}
		seen[id] = true
		for _, entry := range os.Environ() {
			k, v, ok := strings.Cut(entry, "=")
			if ok && k != key && strings.HasPrefix(k, "METON_MANAGED_") && strings.HasSuffix(k, "_KEY_ID") && v == id {
				return "", false
			}
		}
	}
	return os.Getenv("METON_MANAGED_" + purpose + "_KEY_ID"), true
}

/** NewMetonResultControl 缺少受限实现时关闭，不借用普通模型读接口作为写入后备。 */
func NewMetonResultControl(store MetonResultControlStore) *MetonResultControl {
	if store == nil {
		return nil
	}
	return &MetonResultControl{store: store}
}

/** Execute 独立区分观察、选用与只读；超时、来源变化或未知都不自动改成另一种操作。 */
func (s *MetonResultControl) Execute(ctx context.Context, source MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID, action string, q metonmodel.ReconciliationRequest) (json.RawMessage, error) {
	raw, _ := json.Marshal(q)
	validated, err := metonmodel.ReadReconciliation(raw)
	id, allowed := source.ResultControlID(action)
	if s == nil || s.store == nil || err != nil || !allowed || creation == uuid.Nil || operation == uuid.Nil ||
		validated.Admission.Origin.Environment != source.Environment || validated.Admission.Origin.Source != source.Source || validated.Epoch != source.Epoch ||
		validated.Admission.Origin.Caller != caller || validated.Admission.Origin.OperationID != operation.String() {
		return nil, ErrMetonClosed
	}
	ctx, cancel := context.WithDeadline(ctx, time.UnixMilli(q.UntilMS))
	defer cancel()
	guard := func(ctx context.Context) error {
		live, ok := MetonSource()
		current, enabled := source.ResultControlID(action)
		if ctx.Err() != nil || !ok || live != source || !enabled || id != current || !q.Current(time.Now()) {
			return ErrMetonClosed
		}
		return nil
	}
	if guard(ctx) != nil {
		return nil, ErrMetonClosed
	}
	raw, err = s.store.Reconcile(ctx, source, creation, action, *validated, guard)
	if err != nil || guard(ctx) != nil {
		return nil, ErrMetonClosed
	}
	if len(raw) == 0 {
		return nil, nil
	}
	receipt, err := metonmodel.ReadReconciliationReceipt(raw)
	state := "observed"
	if action == "apply" || action == "resolution" {
		state = "resolved"
	}
	if err != nil || receipt.Epoch != source.Epoch || receipt.Origin != q.Admission.Origin || receipt.ReconciliationSelection != q.ReconciliationSelection || receipt.State != state {
		return nil, ErrMetonClosed
	}
	return raw, nil
}
