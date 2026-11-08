package metonmodel

import (
	"encoding/json"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/google/uuid"
)

// ReconciliationSelection 只引用原运营执行及已登记证据，不能传入金额、用量或供应身份。
type ReconciliationSelection struct {
	EvidenceID     string `json:"evidence_id"`
	CaseID         string `json:"case_id"`
	AttemptID      string `json:"attempt_id"`
	ApprovalDigest string `json:"approval_digest"`
}

type ReconciliationRequest struct {
	Version   int       `json:"version"`
	Epoch     int64     `json:"epoch"`
	UntilMS   int64     `json:"until_ms"`
	Admission Admission `json:"admission"`
	ReconciliationSelection
}

// ReconciliationReceipt 只交付核对和选用凭证；完整费用继续沿原结果只读协议取得。
type ReconciliationReceipt struct {
	Version int             `json:"version"`
	Epoch   int64           `json:"epoch"`
	Origin  metonfee.Origin `json:"origin"`
	ReconciliationSelection
	State      string  `json:"state"`
	PriorEvent string  `json:"prior_event"`
	EventID    *string `json:"event_id"`
}

/** 原编号只接受规范 UUID，别名写法不能绕开同一事项比较。 */
func reconciliationID(raw string) bool {
	id, err := uuid.Parse(raw)
	return err == nil && id != uuid.Nil && id.String() == raw
}

/** Valid 只确认引用形状，不把引用或摘要当作已经审核的证明。 */
func (k ReconciliationSelection) Valid() bool {
	return reconciliationID(k.EvidenceID) && reconciliationID(k.CaseID) && reconciliationID(k.AttemptID) && digest.MatchString(k.ApprovalDigest)
}

/** ReadReconciliation 严格固定所有字段，原批准摘要和原编号不随查询续期变化。 */
func ReadReconciliation(raw []byte) (*ReconciliationRequest, error) {
	var q ReconciliationRequest
	if decodeResult(raw, &q) != nil || q.Version != 1 || q.Epoch <= 0 || q.Admission.AcceptedEpoch <= 0 || q.Admission.AcceptedEpoch > q.Epoch || !q.ReconciliationSelection.Valid() || q.UntilMS <= 0 {
		return nil, ErrReference
	}
	admission, _ := json.Marshal(q.Admission)
	if _, err := ReadAdmission(admission); err != nil {
		return nil, ErrReference
	}
	return &q, nil
}

/** Current 只限制这一次控制请求，不延长原批准或给历史 Key 新权限。 */
func (q ReconciliationRequest) Current(now time.Time) bool {
	remaining := time.UnixMilli(q.UntilMS).Sub(now)
	return remaining > 0 && remaining <= 30*time.Second
}

/** ReadReconciliationReceipt 查无不是失败或未执行；这里仅解析已经存在的原凭证。 */
func ReadReconciliationReceipt(raw []byte) (*ReconciliationReceipt, error) {
	var r ReconciliationReceipt
	if decodeResult(raw, &r) != nil || r.Version != 1 || r.Epoch <= 0 || !r.Origin.Valid() || !r.ReconciliationSelection.Valid() || !reconciliationID(r.PriorEvent) {
		return nil, ErrReference
	}
	if r.State == "observed" && r.EventID == nil {
		return &r, nil
	}
	if r.State == "resolved" && r.EventID != nil && reconciliationID(*r.EventID) && *r.EventID != r.PriorEvent {
		return &r, nil
	}
	return nil, ErrReference
}
