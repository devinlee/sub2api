//go:build meton_managed

package metonledger

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math/big"
	"regexp"
	"slices"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/lib/pq"
)

// FeeReport 沿用 S2-03 的供应费用协议，只在确认原受理后交给调用方。
type FeeReport struct {
	Version int             `json:"version"`
	Origin  metonfee.Origin `json:"origin"`
	Item    metonfee.Item   `json:"item"`
}

// SourceChange 为本次净扣款，负值表示按原费项退回原批次。
type SourceChange struct {
	Ordinal     int    `json:"ordinal"`
	CreditEvent string `json:"credit_event"`
	Change      string `json:"change"`
}

type FeePosting struct {
	Report      FeeReport      `json:"report"`
	Funded      string         `json:"funded"`
	Uncovered   string         `json:"uncovered"`
	Change      string         `json:"change"`
	LedgerEvent *string        `json:"ledger_event"`
	Sources     []SourceChange `json:"sources"`
}

// FeeManifest 由供应计费执行方在取得整次调用的费用终局后提供。
type FeeManifest struct {
	Proof       string   `json:"proof"`
	FinalEvents []string `json:"final_events"`
}

type CoverPart struct {
	Ordinal     int    `json:"ordinal"`
	CreditEvent string `json:"credit_event"`
	Amount      string `json:"amount"`
}

type FeeEnding struct {
	FeeManifest
	Request  string      `json:"request"`
	Released []CoverPart `json:"released"`
}

type AdditionalCover struct {
	Request   string      `json:"request"`
	Operation string      `json:"operation"`
	Amount    string      `json:"amount"`
	Covered   bool        `json:"covered"`
	Sources   []CoverPart `json:"sources"`
}

var errOriginalFee = errors.New("invalid original source fee receipt")
var fixedNumber = regexp.MustCompile("^-?(0|[1-9][0-9]{0,11})[.][0-9]{8}$")

// feeCommand 只在绑定的数据库连接上发一次语句。没有返回原凭证时保留未知，不以零费用代替。
func (l *TextLedger) feeCommand(ctx context.Context, o metonfee.Origin, query string, extra []any, dest any) error {
	if o.Environment != l.environment || o.Source != l.source || o.SourceRequestID == "" {
		return errOriginalFee
	}
	params := append(l.args(Call{o.User, o.Account, o.SourceMarker, o.Caller, o.OperationID}), o.SourceRequestID)
	conn, err := l.conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	var raw []byte
	if err = conn.QueryRowContext(ctx, "SELECT meton_ledger."+query, append(params, extra...)...).Scan(&raw); err != nil {
		return err
	}
	if len(raw) == 0 {
		return sql.ErrNoRows
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	return dec.Decode(dest)
}

func verifyReport(r FeeReport, o metonfee.Origin, itemID, eventID string, expected []byte) error {
	if r.Version != 1 || r.Origin != o || r.Item.ChargeItemID != itemID || r.Item.EventID != eventID {
		return errOriginalFee
	}
	wire, err := metonfee.Encode(r.Origin, r.Item)
	if err != nil || (expected != nil && !bytes.Equal(wire, expected)) {
		return errOriginalFee
	}
	return nil
}

func financialNumber(value string) (*big.Rat, bool) {
	if !fixedNumber.MatchString(value) {
		return nil, false
	}
	return new(big.Rat).SetString(value)
}

// verifyPosting 复验回执内的守恒关系，不据此推算新的用户费用或产生资金事件。
func verifyPosting(p FeePosting, o metonfee.Origin, itemID, eventID string, expected []byte) error {
	if err := verifyReport(p.Report, o, itemID, eventID, expected); err != nil {
		return err
	}
	actual, a := financialNumber(p.Report.Item.Amount)
	funded, b := financialNumber(p.Funded)
	gap, c := financialNumber(p.Uncovered)
	change, d := financialNumber(p.Change)
	if !a || !b || !c || !d || funded.Sign() < 0 || gap.Sign() < 0 || p.Report.Item.State == "observed" ||
		new(big.Rat).Add(funded, gap).Cmp(actual) != 0 || (change.Sign() == 0) != (p.LedgerEvent == nil) || p.Sources == nil {
		return errOriginalFee
	}
	sum := new(big.Rat)
	last := 0
	for _, line := range p.Sources {
		value, valid := financialNumber(line.Change)
		if !valid || value.Sign() != change.Sign() || value.Sign() == 0 || line.Ordinal <= last || line.CreditEvent == "" {
			return errOriginalFee
		}
		last = line.Ordinal
		sum.Add(sum, value)
	}
	if sum.Cmp(change) != 0 {
		return errOriginalFee
	}
	return nil
}

func feeValues(i metonfee.Item) []any {
	return []any{i.ChargeItemID, i.EventID, i.Revision, i.PriceVersion, i.Unit, i.Amount}
}

// ObserveFee 保存同一费项的一个累计观察，只有原生最终凭证可以进入 PostFee。
func (l *TextLedger) ObserveFee(ctx context.Context, o metonfee.Origin, i metonfee.Item) (*FeeReport, error) {
	expected, err := metonfee.Encode(o, i)
	if err != nil || i.State != "observed" {
		return nil, errOriginalFee
	}
	var r FeeReport
	if err = l.feeCommand(ctx, o, "observe_text_fee($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)", feeValues(i), &r); err != nil {
		return nil, err
	}
	if err = verifyReport(r, o, i.ChargeItemID, i.EventID, expected); err != nil {
		return nil, err
	}
	return &r, nil
}

func (l *TextLedger) FindFee(ctx context.Context, o metonfee.Origin, itemID, eventID string) (*FeeReport, error) {
	var r FeeReport
	if err := l.feeCommand(ctx, o, "find_text_fee($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)", []any{itemID, eventID}, &r); err != nil {
		return nil, err
	}
	if err := verifyReport(r, o, itemID, eventID, nil); err != nil {
		return nil, err
	}
	return &r, nil
}

// PostFee 每次结算一个费项。没有独立终局清单时保留其余 H；收到清单时扣款和尾部释放同事务。
func (l *TextLedger) PostFee(ctx context.Context, o metonfee.Origin, i metonfee.Item, end *FeeManifest) (*FeePosting, error) {
	expected, err := metonfee.Encode(o, i)
	if err != nil || (i.State != "final" && i.State != "revised") {
		return nil, errOriginalFee
	}
	var proof, manifest any
	if end != nil {
		proof = end.Proof
		manifest = pq.Array(end.FinalEvents)
	}
	args := append(feeValues(i), i.PreviousEventID, proof, manifest)
	var raw json.RawMessage
	if err = l.feeCommand(ctx, o, "post_text_fee($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)", args, &raw); err != nil {
		return nil, err
	}
	p, err := decodePosting(raw, o, i, end)
	if err != nil {
		return nil, err
	}
	if err = verifyPosting(*p, o, i.ChargeItemID, i.EventID, expected); err != nil {
		return nil, err
	}
	return p, nil
}

func (l *TextLedger) FindPosting(ctx context.Context, o metonfee.Origin, itemID, eventID string) (*FeePosting, error) {
	var p FeePosting
	if err := l.feeCommand(ctx, o, "find_text_posting($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)", []any{itemID, eventID}, &p); err != nil {
		return nil, err
	}
	if err := verifyPosting(p, o, itemID, eventID, nil); err != nil {
		return nil, err
	}
	return &p, nil
}

// EndFees 用独立的费用终局证据缩短已确认不再需要的 H，费用未知时不能用空清单调用。
func (l *TextLedger) EndFees(ctx context.Context, o metonfee.Origin, m FeeManifest) (*FeeEnding, error) {
	var e FeeEnding
	if err := l.feeCommand(ctx, o, "end_text_fees($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)", []any{m.Proof, pq.Array(m.FinalEvents)}, &e); err != nil {
		return nil, err
	}
	expected := slices.Clone(m.FinalEvents)
	slices.Sort(expected)
	if e.Request != o.SourceRequestID || e.Proof != m.Proof || len(expected) == 0 || !slices.Equal(expected, e.FinalEvents) {
		return nil, errOriginalFee
	}
	return &e, nil
}

func (l *TextLedger) FindEnding(ctx context.Context, o metonfee.Origin) (*FeeEnding, error) {
	var e FeeEnding
	if err := l.feeCommand(ctx, o, "find_text_ending($1,$2,$3,$4,$5,$6,$7,$8,$9)", nil, &e); err != nil {
		return nil, err
	}
	if e.Request != o.SourceRequestID || e.Proof == "" || len(e.FinalEvents) == 0 {
		return nil, errOriginalFee
	}
	return &e, nil
}

// AddCover 只能按原请求、原价格和一份稳定证明追加整笔预占；拒绝的证明重复提交也只返回原结论。
func (l *TextLedger) AddCover(ctx context.Context, o metonfee.Origin, proof, version, unit, amount string) (*AdditionalCover, error) {
	var c AdditionalCover
	if err := l.feeCommand(ctx, o, "add_text_cover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)", []any{proof, version, unit, amount}, &c); err != nil {
		return nil, err
	}
	if c.Request != o.SourceRequestID || c.Operation != proof || c.Amount != amount || c.Covered != (len(c.Sources) > 0) {
		return nil, errOriginalFee
	}
	return &c, nil
}

func (l *TextLedger) FindCover(ctx context.Context, o metonfee.Origin, proof string) (*AdditionalCover, error) {
	var c AdditionalCover
	if err := l.feeCommand(ctx, o, "find_text_cover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)", []any{proof}, &c); err != nil {
		return nil, err
	}
	if c.Request != o.SourceRequestID || c.Operation != proof || c.Covered != (len(c.Sources) > 0) {
		return nil, errOriginalFee
	}
	return &c, nil
}
