//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"reflect"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
)

// ExecutionResult 关联原响应事实与唯一来源资金凭证；没有 Posting 不表示零费用。
type ExecutionResult struct {
	Version     int                  `json:"version"`
	Origin      metonfee.Origin      `json:"origin"`
	EventID     string               `json:"event_id"`
	Observation metonresult.Snapshot `json:"observation"`
	Posting     *FeePosting          `json:"posting"`
	Ending      *FeeEnding           `json:"ending"`
}

/** CompleteExecution 只提交实际观察；来源按原冻结价格计算费用，本方法没有金额输入或自动重试。 */
func (l *TextLedger) CompleteExecution(ctx context.Context, v *metondispatch.Verified, h *Hold, q *metonexecution.Quote, observation metonresult.Snapshot) (*ExecutionResult, error) {
	if !l.currentSource() || !l.matchesTransport(h, v) || !q.For(v) || v.Context().Epoch != l.epoch ||
		!observation.Valid() || observation.Protocol != q.Record().WireProtocol {
		return nil, errOriginalFee
	}
	// 已执行的事实不再按 Key 的有效期判断；恢复代次与原发送者仍在来源事务中核对。
	spec, _ := json.Marshal(q.Record())
	observed, _ := json.Marshal(observation)
	r, err := l.executionResult(ctx, h.Origin, "complete_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
		[]any{v.Hash(), string(spec), string(observed)})
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(r.Observation, observation) || r.Posting != nil &&
		(r.Posting.Report.Item.PriceVersion != h.PriceVersion || r.Posting.Report.Item.Unit != h.Unit) {
		return nil, errOriginalFee
	}
	return r, nil
}

/** FindExecution 只读原结果；查无、失联、跨代或回执不符均不能产生新调用、扣款或退款。 */
func (l *TextLedger) FindExecution(ctx context.Context, origin metonfee.Origin) (*ExecutionResult, error) {
	return l.executionResult(ctx, origin, "find_execution_result($1,$2,$3,$4,$5,$6,$7,$8,$9)", nil)
}

func (l *TextLedger) executionResult(ctx context.Context, origin metonfee.Origin, query string, extra []any) (*ExecutionResult, error) {
	var raw json.RawMessage
	if err := l.feeCommand(ctx, origin, query, extra, &raw); err != nil {
		return nil, err
	}
	var result ExecutionResult
	if metonexecution.DecodeStrict(raw, &result) != nil || verifyExecution(result, origin) != nil || !l.currentSource() {
		return nil, errOriginalFee
	}
	return &result, nil
}

func verifyExecution(r ExecutionResult, origin metonfee.Origin) error {
	if r.Version != 1 || r.Origin != origin || !origin.Valid() || !originalID(r.EventID) || !r.Observation.Valid() {
		return errOriginalFee
	}
	if !r.Observation.FeeReady {
		if r.Posting != nil || r.Ending != nil {
			return errOriginalFee
		}
		return nil
	}
	if r.Posting == nil || r.Ending == nil || verifyPosting(*r.Posting, origin, origin.SourceRequestID, r.EventID, nil) != nil ||
		r.Posting.Report.Item.Revision != 1 || r.Posting.Report.Item.State != "final" || r.Posting.Report.Item.PreviousEventID != nil ||
		r.Ending.Request != origin.SourceRequestID || r.Ending.Proof != r.EventID || len(r.Ending.FinalEvents) != 1 ||
		r.Ending.FinalEvents[0] != r.EventID || r.Ending.Released == nil {
		return errOriginalFee
	}
	seen := map[string]bool{}
	previous := int(^uint(0) >> 1)
	for _, release := range r.Ending.Released {
		amount, valid := financialNumber(release.Amount)
		if !valid || amount.Sign() <= 0 || !originalID(release.CreditEvent) || seen[release.CreditEvent] || release.Ordinal < 1 || release.Ordinal >= previous {
			return errOriginalFee
		}
		seen[release.CreditEvent] = true
		previous = release.Ordinal
	}
	return nil
}
