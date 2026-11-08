//go:build meton_managed

package metonledger

import (
	"bytes"
	"context"
	"encoding/json"
	"math/big"
	"slices"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/google/uuid"
)

type CorrectionSource struct {
	CreditEvent string `json:"credit_event"`
	Amount      string `json:"amount"`
}

type CorrectionKey struct {
	Item     string `json:"item"`
	Basis    string `json:"basis"`
	Decision string `json:"decision"`
}

type CorrectionRuling struct {
	CorrectionKey
	Version int                `json:"version"`
	Final   bool               `json:"final"`
	Sources []CorrectionSource `json:"sources"`
}

type CorrectionApproval struct {
	CorrectionRuling
	Origin metonfee.Origin `json:"origin"`
	Amount string          `json:"amount"`
}

type CorrectionReceipt struct {
	Approval CorrectionApproval `json:"approval"`
	Journal  string             `json:"journal"`
}

// FeeDispute 的证据由原来源保存。收到该结果的提交者只能转核对。
type FeeDispute struct {
	State         string          `json:"state"`
	Origin        metonfee.Origin `json:"origin"`
	Item          string          `json:"item"`
	ReportedEvent string          `json:"reported_event"`
	Decision      string          `json:"decision"`
	EvidenceID    string          `json:"evidence_id"`
	Evidence      json.RawMessage `json:"evidence"`
}

type FeeReviewRequired struct{ Dispute FeeDispute }

func (e *FeeReviewRequired) Error() string { return "original fee under review" }

func originalID(s string) bool {
	id, err := uuid.Parse(s)
	return err == nil && id != uuid.Nil && id.String() == s
}

func verifyApproval(a CorrectionApproval, o metonfee.Origin, key CorrectionKey) error {
	total, ok := financialNumber(a.Amount)
	if !ok || total.Sign() <= 0 || a.Origin != o || a.CorrectionKey != key || a.Version < 1 ||
		!originalID(key.Item) || !originalID(key.Basis) || !originalID(key.Decision) {
		return errOriginalFee
	}
	previous := ""
	sum := new(big.Rat)
	for _, line := range a.Sources {
		n, ok := financialNumber(line.Amount)
		if !ok || n.Sign() <= 0 || !originalID(line.CreditEvent) || line.CreditEvent <= previous {
			return errOriginalFee
		}
		previous = line.CreditEvent
		sum.Add(sum, n)
	}
	if sum.Cmp(total) != 0 {
		return errOriginalFee
	}
	return nil
}

func keyArgs(k CorrectionKey) []any { return []any{k.Item, k.Basis, k.Decision} }

// ApproveCorrection 固定原裁决的逐批数量，仅批准时没有资金效果。
func (l *TextLedger) ApproveCorrection(ctx context.Context, o metonfee.Origin, ruling CorrectionRuling) (*CorrectionApproval, error) {
	raw, err := json.Marshal(ruling.Sources)
	if err != nil {
		return nil, err
	}
	var r CorrectionApproval
	args := append(keyArgs(ruling.CorrectionKey), ruling.Version, ruling.Final, string(raw))
	if err = l.feeCommand(ctx, o, "approve_text_correction($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)", args, &r); err != nil {
		return nil, err
	}
	if err = verifyApproval(r, o, ruling.CorrectionKey); err != nil {
		return nil, err
	}
	expected := slices.Clone(ruling.Sources)
	slices.SortFunc(expected, func(a, b CorrectionSource) int { return strings.Compare(a.CreditEvent, b.CreditEvent) })
	if r.Version != ruling.Version || r.Final != ruling.Final || !slices.Equal(r.Sources, expected) {
		return nil, errOriginalFee
	}
	return &r, nil
}

func (l *TextLedger) FindDecision(ctx context.Context, o metonfee.Origin, k CorrectionKey) (*CorrectionApproval, error) {
	var r CorrectionApproval
	if err := l.feeCommand(ctx, o, "find_text_decision($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)", keyArgs(k), &r); err != nil {
		return nil, err
	}
	if err := verifyApproval(r, o, k); err != nil {
		return nil, err
	}
	return &r, nil
}

// ApplyCorrection 执行已确认的原版本。执行端不接受替换金额或来源。
func (l *TextLedger) ApplyCorrection(ctx context.Context, o metonfee.Origin, k CorrectionKey, version int) (*CorrectionReceipt, error) {
	return l.correction(ctx, o, k, &version)
}

func (l *TextLedger) FindCorrection(ctx context.Context, o metonfee.Origin, k CorrectionKey) (*CorrectionReceipt, error) {
	return l.correction(ctx, o, k, nil)
}

func (l *TextLedger) correction(ctx context.Context, o metonfee.Origin, k CorrectionKey, version *int) (*CorrectionReceipt, error) {
	var r CorrectionReceipt
	query := "find_text_correction($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)"
	args := keyArgs(k)
	if version != nil {
		query = "apply_text_correction($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)"
		args = append(args, *version)
	}
	if err := l.feeCommand(ctx, o, query, args, &r); err != nil {
		return nil, err
	}
	if err := verifyApproval(r.Approval, o, k); err != nil {
		return nil, err
	}
	if !originalID(r.Journal) || (version != nil && r.Approval.Version != *version) {
		return nil, errOriginalFee
	}
	return &r, nil
}

func verifyDispute(r FeeDispute, o metonfee.Origin, item, event string) error {
	if r.State != "review_required" || r.Origin != o || r.Item != item || r.ReportedEvent != event || !originalID(r.Decision) || !originalID(r.EvidenceID) {
		return errOriginalFee
	}
	var payload struct{ Kind, Event string }
	if err := json.Unmarshal(r.Evidence, &payload); err != nil || payload.Event != event || (payload.Kind != "fee" && payload.Kind != "execution_success") {
		return errOriginalFee
	}
	return nil
}

// decodePosting 仍按既有回执格式校验资金；迟到争议以可区分的错误带回原证据号。
func decodePosting(raw json.RawMessage, o metonfee.Origin, i metonfee.Item, end *FeeManifest) (*FeePosting, error) {
	var envelope struct {
		State string `json:"state"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if envelope.State != "" {
		var report FeeDispute
		if err := d.Decode(&report); err != nil {
			return nil, err
		}
		if err := verifyDispute(report, o, i.ChargeItemID, i.EventID); err != nil {
			return nil, err
		}
		var proposed struct {
			Kind, Price, Unit, Amount string
			Revision                  int32
			Previous, Proof           *string
			FinalEvents               []string `json:"final_events"`
		}
		if err := json.Unmarshal(report.Evidence, &proposed); err != nil || proposed.Kind != "fee" || proposed.Price != i.PriceVersion ||
			proposed.Unit != i.Unit || proposed.Amount != i.Amount || proposed.Revision != i.Revision ||
			(proposed.Previous == nil) != (i.PreviousEventID == nil) || (proposed.Previous != nil && *proposed.Previous != *i.PreviousEventID) ||
			(proposed.Proof == nil) != (end == nil) {
			return nil, errOriginalFee
		}
		if end != nil {
			events := slices.Clone(end.FinalEvents)
			slices.Sort(events)
			if *proposed.Proof != end.Proof || !slices.Equal(proposed.FinalEvents, events) {
				return nil, errOriginalFee
			}
		} else if proposed.FinalEvents != nil {
			return nil, errOriginalFee
		}
		return nil, &FeeReviewRequired{report}
	}
	var posting FeePosting
	if err := d.Decode(&posting); err != nil {
		return nil, err
	}
	return &posting, nil
}

func (l *TextLedger) NoteLateSuccess(ctx context.Context, o metonfee.Origin, item, event, proof string) (*FeeDispute, error) {
	var r FeeDispute
	if err := l.feeCommand(ctx, o, "note_late_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)", []any{item, event, proof}, &r); err != nil {
		return nil, err
	}
	if err := verifyDispute(r, o, item, event); err != nil {
		return nil, err
	}
	var evidence struct{ Kind, Proof string }
	if err := json.Unmarshal(r.Evidence, &evidence); err != nil || evidence.Kind != "execution_success" || evidence.Proof != proof {
		return nil, errOriginalFee
	}
	return &r, nil
}

// FindDisputes 在原回复丢失时按提交者已知的事件号读取全部矛盾凭证，没有提交入口。
func (l *TextLedger) FindDisputes(ctx context.Context, o metonfee.Origin, item, event string) ([]FeeDispute, error) {
	var found []FeeDispute
	if err := l.feeCommand(ctx, o, "list_text_disputes($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)", []any{item, event}, &found); err != nil {
		return nil, err
	}
	if found == nil {
		return nil, errOriginalFee
	}
	for _, r := range found {
		if err := verifyDispute(r, o, item, event); err != nil {
			return nil, err
		}
	}
	return found, nil
}
