//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"math/big"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

// ShortfallKey 固定原费用和本次已审核子步骤，不接受金额、价格或来源批次。
type ShortfallKey struct {
	ItemID         string `json:"item_id"`
	BasisEvent     string `json:"basis_event"`
	CommandID      string `json:"command_id"`
	CaseID         string `json:"case_id"`
	AttemptID      string `json:"attempt_id"`
	ApprovalDigest string `json:"approval_digest"`
}

// ShortfallResolution 区分已覆盖与确定无资金效果；未知不使用该结构伪造终态。
type ShortfallResolution struct {
	Version         int         `json:"version"`
	CommandID       string      `json:"command_id"`
	CaseID          string      `json:"case_id"`
	AttemptID       string      `json:"attempt_id"`
	ApprovalDigest  string      `json:"approval_digest"`
	State           string      `json:"state"`
	Missing         string      `json:"missing"`
	AvailableBefore string      `json:"available_before"`
	Basis           FeePosting  `json:"basis"`
	Result          *FeePosting `json:"result"`
}

/** 原子命令和审核身份独立；换账号、费项或大小写编号都不是同一个请求。 */
func validShortfallKey(k ShortfallKey) bool {
	return originalID(k.ItemID) && originalID(k.BasisEvent) && originalID(k.CommandID) &&
		originalID(k.CaseID) && originalID(k.AttemptID) && resultDigest(k.ApprovalDigest)
}

/** CoverShortfall 只发一次受限语句；未知提交由调用方按原编号查询，不在适配内重试。 */
func (l *TextLedger) CoverShortfall(ctx context.Context, o metonfee.Origin, k ShortfallKey, until time.Time) (*ShortfallResolution, error) {
	now := time.Now()
	if !until.After(now) || until.After(now.Add(30*time.Second)) {
		return nil, errOriginalFee
	}
	bounded, cancel := context.WithDeadline(ctx, until)
	defer cancel()
	return l.shortfall(bounded, o, k, "cover_text_shortfall($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)",
		[]any{k.ItemID, k.BasisEvent, k.CommandID, k.CaseID, k.AttemptID, k.ApprovalDigest, until})
}

/** FindShortfall 只找原子命令；查无不是“未执行”的证据，也不能触发资金写入。 */
func (l *TextLedger) FindShortfall(ctx context.Context, o metonfee.Origin, k ShortfallKey) (*ShortfallResolution, error) {
	bounded, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return l.shortfall(bounded, o, k, "find_text_shortfall($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)", []any{k.CommandID})
}

/** 当前连接配置在前后均须保持；后到响应不能按恢复后的新代次交付。 */
func (l *TextLedger) shortfall(ctx context.Context, o metonfee.Origin, k ShortfallKey, query string, extra []any) (*ShortfallResolution, error) {
	if !l.currentSource() || !o.Valid() || !validShortfallKey(k) || k.ItemID != o.SourceRequestID {
		return nil, errOriginalFee
	}
	var raw json.RawMessage
	if err := l.feeCommand(ctx, o, query, extra, &raw); err != nil {
		return nil, err
	}
	r, err := decodeShortfall(raw, o, k)
	if err != nil || !l.currentSource() || ctx.Err() != nil {
		return nil, errOriginalFee
	}
	return r, nil
}

/** 仅核对原回执守恒和修订链，不在 Meton 之外另建可写余额或重新计价。 */
func decodeShortfall(raw []byte, o metonfee.Origin, k ShortfallKey) (*ShortfallResolution, error) {
	var r ShortfallResolution
	if metonexecution.DecodeStrict(raw, &r) != nil || verifyShortfall(r, o, k) != nil {
		return nil, errOriginalFee
	}
	return &r, nil
}

/** 明确无效果与已覆盖分别校验；旧费用保留，新增修订只能覆盖原差额。 */
func verifyShortfall(r ShortfallResolution, o metonfee.Origin, k ShortfallKey) error {
	if !o.Valid() || !validShortfallKey(k) || k.ItemID != o.SourceRequestID || r.Version != 1 ||
		r.CommandID != k.CommandID || r.CaseID != k.CaseID || r.AttemptID != k.AttemptID || r.ApprovalDigest != k.ApprovalDigest ||
		verifyPosting(r.Basis, o, k.ItemID, k.BasisEvent, nil) != nil {
		return errOriginalFee
	}
	missing, a := financialNumber(r.Missing)
	available, b := financialNumber(r.AvailableBefore)
	if !a || !b || missing.Sign() <= 0 || available.Sign() < 0 || r.Missing != r.Basis.Uncovered {
		return errOriginalFee
	}
	if r.State == "funds_unavailable" {
		if r.Result == nil && available.Cmp(missing) < 0 {
			return nil
		}
		return errOriginalFee
	}
	if r.State != "covered" || r.Result == nil || available.Cmp(missing) < 0 {
		return errOriginalFee
	}
	p := r.Result
	item, prior := p.Report.Item, r.Basis.Report.Item
	if verifyPosting(*p, o, k.ItemID, item.EventID, nil) != nil || item.EventID == k.BasisEvent ||
		item.State != "revised" || prior.Revision == 2147483647 || item.Revision != prior.Revision+1 ||
		item.PreviousEventID == nil || *item.PreviousEventID != k.BasisEvent || item.PriceVersion != prior.PriceVersion ||
		item.Unit != prior.Unit || item.Amount != prior.Amount || p.Funded != prior.Amount || p.Uncovered != "0.00000000" || p.Change != r.Missing {
		return errOriginalFee
	}
	funded, _ := financialNumber(r.Basis.Funded)
	next, _ := financialNumber(p.Funded)
	if new(big.Rat).Add(funded, missing).Cmp(next) != 0 {
		return errOriginalFee
	}
	for _, line := range p.Sources {
		if !originalID(line.CreditEvent) {
			return errOriginalFee
		}
	}
	return nil
}
