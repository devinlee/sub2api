package metonmodel

import (
	"encoding/json"
	"math/big"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

// ShortfallSelection 不含金额或新派发信息；审核身份仅由受限运营接缝确认。
type ShortfallSelection struct {
	CommandID      string `json:"command_id"`
	CaseID         string `json:"case_id"`
	AttemptID      string `json:"attempt_id"`
	ApprovalDigest string `json:"approval_digest"`
	BasisEvent     string `json:"basis_event"`
}

type ShortfallRequest struct {
	Version   int       `json:"version"`
	Epoch     int64     `json:"epoch"`
	UntilMS   int64     `json:"until_ms"`
	Admission Admission `json:"admission"`
	ShortfallSelection
}

// 原费用与覆盖修订分开交接；资金修订不替换首次供应观察或其用量。
type ShortfallReceipt struct {
	Version int             `json:"version"`
	Epoch   int64           `json:"epoch"`
	Origin  metonfee.Origin `json:"origin"`
	ShortfallSelection
	State    string     `json:"state"`
	Original ResultFee  `json:"original"`
	Coverage *ResultFee `json:"coverage"`
}

/** Valid 只校验不可变引用，持有 UUID 和摘要不等于具备执行权限。 */
func (s ShortfallSelection) Valid() bool {
	return reconciliationID(s.CommandID) && reconciliationID(s.CaseID) && reconciliationID(s.AttemptID) &&
		reconciliationID(s.BasisEvent) && digest.MatchString(s.ApprovalDigest)
}

/** ReadShortfall 要求完整原受理和规范字段，拒绝重复键、额外金额和字段别名。 */
func ReadShortfall(raw []byte) (*ShortfallRequest, error) {
	var q ShortfallRequest
	if decodeResult(raw, &q) != nil || q.Version != 1 || q.Epoch <= 0 || q.Epoch != q.Admission.AcceptedEpoch || q.UntilMS <= 0 || !q.ShortfallSelection.Valid() {
		return nil, ErrReference
	}
	encoded, _ := json.Marshal(q.Admission)
	if _, err := ReadAdmission(encoded); err != nil {
		return nil, ErrReference
	}
	return &q, nil
}

/** Current 限制本次调用，不延长原批准，也不授予新的子步骤。 */
func (q ShortfallRequest) Current(now time.Time) bool {
	remaining := time.UnixMilli(q.UntilMS).Sub(now)
	return remaining > 0 && remaining <= 30*time.Second
}

/** 核对原来源回执守恒，不在请求方重新计价。 */
func shortfallFee(f ResultFee, o metonfee.Origin) bool {
	encoded, _ := json.Marshal(f.Reference)
	if _, err := ReadFee(encoded); err != nil || f.Reference.Origin != o || f.Reference.Item.ChargeItemID != o.SourceRequestID ||
		!amount.MatchString(f.Funded) || !amount.MatchString(f.Uncovered) {
		return false
	}
	funded, _ := new(big.Rat).SetString(f.Funded)
	gap, _ := new(big.Rat).SetString(f.Uncovered)
	total, _ := new(big.Rat).SetString(f.Reference.Item.Amount)
	return funded != nil && gap != nil && total != nil && new(big.Rat).Add(funded, gap).Cmp(total) == 0
}

/** ReadShortfallReceipt 已覆盖与确定无效果分开；没有回执不构造“未执行”。 */
func ReadShortfallReceipt(raw []byte) (*ShortfallReceipt, error) {
	var r ShortfallReceipt
	if decodeResult(raw, &r) != nil || r.Version != 1 || r.Epoch <= 0 || !r.Origin.Valid() || !r.ShortfallSelection.Valid() ||
		!shortfallFee(r.Original, r.Origin) || r.Original.Uncovered == "0.00000000" {
		return nil, ErrReference
	}
	original := r.Original.Reference.Item
	if original.EventID != r.BasisEvent || original.State != "final" || original.Revision != 1 || original.PreviousEventID != nil {
		return nil, ErrReference
	}
	if r.State == "funds_unavailable" && r.Coverage == nil {
		return &r, nil
	}
	if r.State != "covered" || r.Coverage == nil || !shortfallFee(*r.Coverage, r.Origin) {
		return nil, ErrReference
	}
	covered := r.Coverage.Reference.Item
	if covered.State != "revised" || covered.Revision != 2 || covered.EventID == original.EventID ||
		covered.PreviousEventID == nil || *covered.PreviousEventID != original.EventID || covered.Amount != original.Amount ||
		covered.PriceVersion != original.PriceVersion || covered.Unit != original.Unit || r.Coverage.Uncovered != "0.00000000" || r.Coverage.Funded != original.Amount {
		return nil, ErrReference
	}
	return &r, nil
}
