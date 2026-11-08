//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"strconv"
	"strings"
	"time"
)

type RestoredShortfallResult struct {
	Version        int                  `json:"version"`
	RequestID      string               `json:"request_id"`
	ItemID         string               `json:"item_id"`
	BasisEvent     string               `json:"basis_event"`
	CommandID      string               `json:"command_id"`
	CaseID         string               `json:"case_id"`
	AttemptID      string               `json:"attempt_id"`
	OriginalDigest string               `json:"original_digest"`
	OriginalEpoch  int64                `json:"original_epoch"`
	AuthorityEpoch int64                `json:"authority_epoch"`
	Generation     int32                `json:"generation"`
	ReviewDigest   string               `json:"review_digest"`
	PreviousDigest *string              `json:"previous_digest"`
	ValidUntil     time.Time            `json:"valid_until"`
	State          string               `json:"state"`
	Result         *ShortfallResolution `json:"result"`
}

/** 三种动作只发一次语句，HTTP 身份核验和原资金事务在来源侧同一提交中完成。 */
func (l *TextLedger) RestoredShortfall(ctx context.Context, action string, q metonmodel.RestoredShortfallRequest, a metonmodel.RestoredShortfallAccess) (*RestoredShortfallResult, error) {
	raw, _ := json.Marshal(q)
	if _, err := metonmodel.ReadRestoredShortfall(action, raw); err != nil || !l.currentSource() || q.Epoch != l.epoch ||
		a.KeyID == "" || a.CreatorID < 1 || a.Revision.IsZero() || !resultDigest(a.Witness) || !validCorrectionPermit(a.Until, time.Now()) {
		return nil, errOriginalFee
	}
	bounded, cancel := context.WithDeadline(ctx, a.Until)
	defer cancel()
	s, k := q.Selection, q.Authority
	extra := []any{s.CommandID, k.Generation, k.ReviewDigest}
	name := ""
	switch action {
	case "approve":
		r := q.Review
		valid := time.UnixMilli(r.ValidUntilMS)
		if !valid.After(time.Now()) || valid.After(time.Now().Add(365*24*time.Hour)) || a.Until.After(valid) {
			return nil, errOriginalFee
		}
		name = "http_approve_restored_shortfall"
		extra = []any{q.Admission.Origin.SourceRequestID, s.BasisEvent, s.CommandID, s.CaseID, s.AttemptID, s.ApprovalDigest, k.OriginalEpoch, k.Generation, k.ReviewDigest, r.PreviousDigest, valid, a.Until}
	case "apply":
		name = "http_cover_restored_shortfall"
		extra = append(extra, a.Until)
	case "resolution":
		name = "http_find_restored_shortfall_approval"
	default:
		return nil, errOriginalFee
	}
	extra = append(extra, a.KeyID, a.CreatorID, a.Revision, a.Until.UnixMilli(), a.Witness)
	params := make([]string, 9+len(extra))
	for i := range params {
		params[i] = "$" + strconv.Itoa(i+1)
	}
	var result json.RawMessage
	if err := l.feeCommand(bounded, q.Admission.Origin, name+"("+strings.Join(params, ",")+")", extra, &result); err != nil {
		return nil, err
	}
	r, err := decodeRestoredShortfall(result, q, action)
	if err != nil || !l.currentSource() || bounded.Err() != nil {
		return nil, errOriginalFee
	}
	return r, nil
}

/** 响应保留原费用和原命令；当前批准代次不能改写原受理。 */
func decodeRestoredShortfall(raw []byte, q metonmodel.RestoredShortfallRequest, action string) (*RestoredShortfallResult, error) {
	var r RestoredShortfallResult
	s, k, o := q.Selection, q.Authority, q.Admission.Origin
	if metonexecution.DecodeStrict(raw, &r) != nil || r.Version != 1 || r.RequestID != o.SourceRequestID || r.ItemID != o.SourceRequestID ||
		r.BasisEvent != s.BasisEvent || r.CommandID != s.CommandID || r.CaseID != s.CaseID || r.AttemptID != s.AttemptID || r.OriginalDigest != s.ApprovalDigest ||
		r.OriginalEpoch != k.OriginalEpoch || r.AuthorityEpoch < k.OriginalEpoch || r.AuthorityEpoch > q.Epoch || r.AuthorityEpoch <= q.Admission.AcceptedEpoch ||
		(action != "resolution" && r.AuthorityEpoch != q.Epoch) || r.Generation != k.Generation || r.ReviewDigest != k.ReviewDigest ||
		r.ValidUntil.IsZero() || (r.PreviousDigest == nil) != (r.Generation == 1) ||
		(r.PreviousDigest != nil && (!resultDigest(*r.PreviousDigest) || *r.PreviousDigest == r.ReviewDigest)) {
		return nil, errOriginalFee
	}
	if action == "approve" && (q.Review == nil || !r.ValidUntil.Equal(time.UnixMilli(q.Review.ValidUntilMS)) ||
		!sameShortfallDigest(r.PreviousDigest, q.Review.PreviousDigest)) {
		return nil, errOriginalFee
	}
	if action == "apply" && r.State != "resolved" {
		return nil, errOriginalFee
	}
	switch r.State {
	case "approved", "superseded":
		if r.Result != nil {
			return nil, errOriginalFee
		}
	case "resolved":
		key := ShortfallKey{ItemID: o.SourceRequestID, BasisEvent: s.BasisEvent, CommandID: s.CommandID, CaseID: s.CaseID, AttemptID: s.AttemptID, ApprovalDigest: s.ApprovalDigest}
		if r.Result == nil || verifyShortfall(*r.Result, o, key) != nil || r.Result.Basis.Report.Item.PriceVersion != q.Admission.Pricing.Version ||
			r.Result.Basis.Report.Item.Unit != q.Admission.Pricing.Unit {
			return nil, errOriginalFee
		}
	default:
		return nil, errOriginalFee
	}
	return &r, nil
}

func sameShortfallDigest(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

/** 原无效果或已覆盖回执只读交回，不因缺当前批准而丢掉已经发生的原事实。 */
func (l *TextLedger) ReadRestoredShortfallOriginal(ctx context.Context, q metonmodel.RestoredShortfallRequest, a metonmodel.RestoredShortfallAccess) (*ShortfallResolution, error) {
	raw, _ := json.Marshal(q)
	if _, err := metonmodel.ReadRestoredShortfall("original", raw); err != nil || !l.currentSource() || q.Epoch != l.epoch ||
		a.KeyID == "" || a.CreatorID < 1 || a.Revision.IsZero() || !resultDigest(a.Witness) || !validCorrectionPermit(a.Until, time.Now()) {
		return nil, errOriginalFee
	}
	bounded, cancel := context.WithDeadline(ctx, a.Until)
	defer cancel()
	s, o := q.Selection, q.Admission.Origin
	extra := []any{s.CommandID, s.ApprovalDigest, a.KeyID, a.CreatorID, a.Revision, a.Until.UnixMilli(), a.Witness}
	var result json.RawMessage
	if err := l.feeCommand(bounded, o, "http_find_restored_shortfall_original($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)", extra, &result); err != nil {
		return nil, err
	}
	r, err := decodeShortfall(result, o, ShortfallKey{ItemID: o.SourceRequestID, BasisEvent: s.BasisEvent, CommandID: s.CommandID, CaseID: s.CaseID, AttemptID: s.AttemptID, ApprovalDigest: s.ApprovalDigest})
	if err != nil || !l.currentSource() || bounded.Err() != nil || r.Basis.Report.Item.PriceVersion != q.Admission.Pricing.Version || r.Basis.Report.Item.Unit != q.Admission.Pricing.Unit {
		return nil, errOriginalFee
	}
	return r, nil
}
