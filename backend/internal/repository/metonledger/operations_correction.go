//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

// OperationsCorrectionKey 固定原裁决和某一代批准。续审沿用原裁决和 Attempt。
type OperationsCorrectionKey struct {
	CorrectionKey
	CaseID         string `json:"case_id"`
	AttemptID      string `json:"attempt_id"`
	RulingVersion  int32  `json:"ruling_version"`
	Generation     int32  `json:"generation"`
	ApprovalDigest string `json:"approval_digest"`
}

// OperationsCorrectionApproval 只由审核侧提供，执行侧没有金额或选批参数。
type OperationsCorrectionApproval struct {
	PreviousDigest *string
	Final          bool
	Sources        []CorrectionSource
	ValidUntil     time.Time
}

type OperationsCorrectionResult struct {
	FormatVersion  int                `json:"format_version"`
	CaseID         string             `json:"case_id"`
	AttemptID      string             `json:"attempt_id"`
	Epoch          int64              `json:"epoch"`
	Generation     int32              `json:"generation"`
	ApprovalDigest string             `json:"approval_digest"`
	ValidUntil     time.Time          `json:"valid_until"`
	Approval       CorrectionApproval `json:"approval"`
	State          string             `json:"state"`
	Journal        *string            `json:"journal"`
}

func (k OperationsCorrectionKey) valid() bool {
	return originalID(k.Item) && originalID(k.Basis) && originalID(k.Decision) && originalID(k.CaseID) &&
		originalID(k.AttemptID) && k.RulingVersion > 0 && k.Generation > 0 && resultDigest(k.ApprovalDigest)
}

func (k OperationsCorrectionKey) args() []any {
	return []any{k.Item, k.Basis, k.Decision, k.CaseID, k.AttemptID, k.RulingVersion, k.Generation, k.ApprovalDigest}
}

func validCorrectionPermit(until, now time.Time) bool {
	return until.After(now) && !until.After(now.Add(30*time.Second))
}

/** ApproveOperationsCorrection 固定原来源及有效期；审批连接仅发一次可自动提交的语句。 */
func (l *TextLedger) ApproveOperationsCorrection(ctx context.Context, o metonfee.Origin, k OperationsCorrectionKey, a OperationsCorrectionApproval,
	permit time.Time) (*OperationsCorrectionResult, error) {
	now := time.Now()
	// PostgreSQL 时间戳精确到微秒。先固定精度再核对回执，不因客户端纳秒或时区产生新的审核身份。
	valid := a.ValidUntil.UTC().Truncate(time.Microsecond)
	if !validCorrectionPermit(permit, now) || !valid.After(now) || valid.After(now.Add(365*24*time.Hour)) ||
		len(a.Sources) == 0 || len(a.Sources) > 64 || (a.PreviousDigest == nil) != (k.Generation == 1) ||
		(a.PreviousDigest != nil && (!resultDigest(*a.PreviousDigest) || *a.PreviousDigest == k.ApprovalDigest)) {
		return nil, errOriginalFee
	}
	selected := slices.Clone(a.Sources)
	slices.SortFunc(selected, func(a, b CorrectionSource) int { return strings.Compare(a.CreditEvent, b.CreditEvent) })
	for i, line := range selected {
		n, ok := financialNumber(line.Amount)
		if !ok || n.Sign() <= 0 || !originalID(line.CreditEvent) || (i > 0 && selected[i-1].CreditEvent == line.CreditEvent) {
			return nil, errOriginalFee
		}
	}
	raw, err := json.Marshal(selected)
	if err != nil {
		return nil, err
	}
	deadline := permit
	if valid.Before(deadline) {
		deadline = valid
	}
	bounded, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()
	params := append(k.args(), a.PreviousDigest, a.Final, string(raw), valid, permit)
	r, err := l.operationsCorrection(bounded, o, k,
		"approve_operations_correction", params, true)
	if err != nil {
		return nil, err
	}
	if !r.ValidUntil.Equal(valid) || r.Approval.Final != a.Final || !slices.Equal(r.Approval.Sources, selected) {
		return nil, errOriginalFee
	}
	return r, nil
}

/** ApplyOperationsCorrection 只引用既有批准。响应丢失由调用方转查询，适配不再派发。 */
func (l *TextLedger) ApplyOperationsCorrection(ctx context.Context, o metonfee.Origin, k OperationsCorrectionKey, permit time.Time) (*OperationsCorrectionResult, error) {
	if !validCorrectionPermit(permit, time.Now()) {
		return nil, errOriginalFee
	}
	bounded, cancel := context.WithDeadline(ctx, permit)
	defer cancel()
	r, err := l.operationsCorrection(bounded, o, k,
		"apply_operations_correction", append(k.args(), permit), true)
	if err != nil {
		return nil, err
	}
	if r.State != "applied" {
		return nil, errOriginalFee
	}
	return r, nil
}

/** FindOperationsCorrection 经只读连接查询指定批准。当前来源可以读历史代次的事实。 */
func (l *TextLedger) FindOperationsCorrection(ctx context.Context, o metonfee.Origin, k OperationsCorrectionKey) (*OperationsCorrectionResult, error) {
	bounded, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return l.operationsCorrection(bounded, o, k,
		"find_operations_correction", k.args(), false)
}

func (l *TextLedger) operationsCorrection(ctx context.Context, o metonfee.Origin, k OperationsCorrectionKey, query string,
	params []any, write bool) (*OperationsCorrectionResult, error) {
	if !l.currentSource() || !o.Valid() || !k.valid() {
		return nil, errOriginalFee
	}
	var raw json.RawMessage
	if err := l.correctionCommand(ctx, o, query, params, &raw); err != nil {
		return nil, err
	}
	r, err := decodeOperationsCorrection(raw, o, k, l.epoch, write)
	if err != nil || !l.currentSource() || ctx.Err() != nil {
		return nil, errOriginalFee
	}
	return r, nil
}

func decodeOperationsCorrection(raw []byte, o metonfee.Origin, k OperationsCorrectionKey, epoch int64, write bool) (*OperationsCorrectionResult, error) {
	var r OperationsCorrectionResult
	if metonexecution.DecodeStrict(raw, &r) != nil || r.FormatVersion != 1 || r.CaseID != k.CaseID || r.AttemptID != k.AttemptID ||
		r.Generation != k.Generation || r.ApprovalDigest != k.ApprovalDigest || r.Epoch < 1 || r.Epoch > epoch || (write && r.Epoch != epoch) ||
		r.ValidUntil.IsZero() || r.Approval.Version != int(k.RulingVersion) || len(r.Approval.Sources) > 64 ||
		verifyApproval(r.Approval, o, k.CorrectionKey) != nil {
		return nil, errOriginalFee
	}
	switch r.State {
	case "approved", "superseded":
		if r.Journal != nil {
			return nil, errOriginalFee
		}
	case "applied":
		if r.Journal == nil || !originalID(*r.Journal) {
			return nil, errOriginalFee
		}
	default:
		return nil, errOriginalFee
	}
	return &r, nil
}
