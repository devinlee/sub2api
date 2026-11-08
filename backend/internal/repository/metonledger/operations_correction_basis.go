//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"math/big"
	"reflect"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
)

// CorrectionBasisSnapshot 固定分页归属和最新裁决状态，不能用另一账号或恢复代次接续。
type CorrectionBasisSnapshot = metonmodel.CorrectionBasisSnapshot
type CorrectionBasisCursor = metonmodel.CorrectionBasisCursor

type CorrectionBasisRow struct {
	CreditEvent     string `json:"credit_event"`
	Kind            string `json:"kind"`
	NetCharged      string `json:"net_charged"`
	Returned        string `json:"returned"`
	PendingApproved string `json:"pending_approved"`
}

type CorrectionBasisPage struct {
	FormatVersion int                     `json:"format_version"`
	Report        FeeReport               `json:"report"`
	Funded        string                  `json:"funded"`
	Uncovered     string                  `json:"uncovered"`
	Snapshot      CorrectionBasisSnapshot `json:"snapshot"`
	Final         *bool                   `json:"final"`
	Rows          []CorrectionBasisRow    `json:"rows"`
	Next          *CorrectionBasisCursor  `json:"next"`
}

/** ReadOperationsCorrectionBasis 只读限定数量的原批次。旧游标失效时由调用方从第一页重新核对。 */
func (l *TextLedger) ReadOperationsCorrectionBasis(ctx context.Context, o metonfee.Origin, item, basis string,
	limit int, cursor *CorrectionBasisCursor) (*CorrectionBasisPage, error) {
	if !l.currentSource() || !o.Valid() || !originalID(item) || !originalID(basis) || limit < 1 || limit > 64 {
		return nil, errOriginalFee
	}
	var param any
	if cursor != nil {
		if !originalID(cursor.After) || !cursor.Snapshot.Matches(o, item, basis, l.epoch) {
			return nil, errOriginalFee
		}
		encoded, err := json.Marshal(cursor)
		if err != nil {
			return nil, err
		}
		param = string(encoded)
	}
	bounded, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var raw json.RawMessage
	if err := l.correctionCommand(bounded, o, "read_operations_correction_basis",
		[]any{item, basis, limit, param}, &raw); err != nil {
		return nil, err
	}
	var page CorrectionBasisPage
	if metonexecution.DecodeStrict(raw, &page) != nil || !l.currentSource() || bounded.Err() != nil ||
		!page.valid(o, item, basis, l.epoch, limit, cursor) {
		return nil, errOriginalFee
	}
	return &page, nil
}

func (p CorrectionBasisPage) valid(o metonfee.Origin, item, basis string, epoch int64, limit int, cursor *CorrectionBasisCursor) bool {
	if p.FormatVersion != 1 || p.Rows == nil || len(p.Rows) > limit || !p.Snapshot.Matches(o, item, basis, epoch) ||
		(p.Final == nil) != (p.Snapshot.Decision == nil) || verifyReport(p.Report, o, item, basis, nil) != nil {
		return false
	}
	funded, f := financialNumber(p.Funded)
	uncovered, u := financialNumber(p.Uncovered)
	total, t := financialNumber(p.Report.Item.Amount)
	if !f || !u || !t || funded.Sign() < 0 || uncovered.Sign() < 0 || new(big.Rat).Add(funded, uncovered).Cmp(total) != 0 {
		return false
	}
	after := ""
	if cursor != nil {
		if !reflect.DeepEqual(cursor.Snapshot, p.Snapshot) {
			return false
		}
		after = cursor.After
	}
	pageTotal := new(big.Rat)
	for _, row := range p.Rows {
		net, n := financialNumber(row.NetCharged)
		returned, r := financialNumber(row.Returned)
		pending, a := financialNumber(row.PendingApproved)
		if !n || !r || !a || !originalID(row.CreditEvent) || row.CreditEvent <= after ||
			(row.Kind != "grant" && row.Kind != "purchase") || returned.Sign() < 0 || pending.Sign() < 0 ||
			new(big.Rat).Add(returned, pending).Cmp(net) > 0 ||
			(p.Snapshot.Decision == nil && returned.Sign() != 0) || ((p.Snapshot.Decision == nil || p.Snapshot.Applied) && pending.Sign() != 0) {
			return false
		}
		after = row.CreditEvent
		pageTotal.Add(pageTotal, net)
	}
	if pageTotal.Cmp(funded) > 0 || (cursor == nil && p.Next == nil && pageTotal.Cmp(funded) != 0) {
		return false
	}
	return p.Next == nil || (len(p.Rows) == limit && p.Next.After == after && reflect.DeepEqual(p.Next.Snapshot, p.Snapshot))
}
