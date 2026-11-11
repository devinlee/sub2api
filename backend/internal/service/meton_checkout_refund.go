package service

import (
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
)

var refundActions = [...]string{"refund_quote", "refund_quote_status", "refund_confirm", "refund_status"}
var refundUnits = regexp.MustCompile(`^(0|[1-9][0-9]{0,11})[.][0-9]{8}$`)
var refundVersion = regexp.MustCompile(`^[0-9a-f]{64}$`)

/** IsCheckoutRefund 只认本版的四项专用权限。收银台交接凭据不能代替当前会员会话。 */
func IsCheckoutRefund(action string) bool {
	return action == "refund_cancel" || slices.Contains(refundActions[:], action)
}
func CheckoutReadAction(action string) bool {
	return action == "status" || action == "order" || action == "refund_quote_status" || action == "refund_status" || action == "dispute_status" || action == "closure_page" || action == "closure_scope" || action == "closure_refunds"
}

type RefundSelection struct {
	Order  int64      `json:"order,string"`
	Part   *uuid.UUID `json:"part,omitempty"`
	Cutoff *uuid.UUID `json:"cutoff,omitempty"`
	Basis  string     `json:"basis"`
	Units  *string    `json:"units,omitempty"`
	Fen    *int64     `json:"fen,string,omitempty"`
}

func (r *RefundSelection) valid() bool {
	if r == nil || r.Order < 1 || (r.Part == nil) == (r.Cutoff == nil) || r.Part != nil && *r.Part == uuid.Nil || r.Cutoff != nil && *r.Cutoff == uuid.Nil {
		return false
	}
	switch r.Basis {
	case "purchased_source":
		return r.Units != nil && r.Fen == nil && refundUnits.MatchString(*r.Units) && *r.Units != "0.00000000"
	case "unposted_cash":
		return r.Units == nil && r.Fen != nil && *r.Fen > 0
	}
	return false
}

type RefundConfirmation struct {
	Quote        uuid.UUID `json:"quote"`
	BasisVersion string    `json:"basisVersion"`
	Fen          int64     `json:"fen,string"`
}
type RefundCancellation struct {
	Refund  uuid.UUID `json:"refund"`
	Version int64     `json:"version"`
}
type CheckoutRefundQuote struct {
	State        string           `json:"state"`
	Quote        uuid.UUID        `json:"quote"`
	Order        int64            `json:"order,omitempty"`
	Basis        string           `json:"basis,omitempty"`
	BasisVersion string           `json:"basisVersion,omitempty"`
	ExpiresAt    *time.Time       `json:"expiresAt,omitempty"`
	Currency     string           `json:"currency,omitempty"`
	Fen          *int64           `json:"fen,omitempty"`
	Units        *string          `json:"units,omitempty"`
	Selection    *RefundSelection `json:"selection"`
}
type CheckoutRefundDecision struct {
	State        string     `json:"state"`
	Intent       uuid.UUID  `json:"intent"`
	Quote        uuid.UUID  `json:"quote"`
	BasisVersion string     `json:"basisVersion,omitempty"`
	Order        int64      `json:"order,omitempty"`
	Basis        string     `json:"basis,omitempty"`
	Fen          int64      `json:"fen,omitempty"`
	Units        *string    `json:"units,omitempty"`
	Refund       *uuid.UUID `json:"refund,omitempty"`
	RefundOrder  string     `json:"refundOrder,omitempty"`
	Phase        string     `json:"phase,omitempty"`
	Version      int64      `json:"version,omitempty"`
}

/** parseMemberRefund 只解析从账号域传入的本次会话和原对象，严格解析器拒绝混入收银台 Cookie 或模型参数。 */
func (s *MetonCheckout) parseMemberRefund(raw []byte, action string, creation, intent uuid.UUID) (*CheckoutRequest, error) {
	var req struct {
		Version      int                 `json:"version"`
		Origin       CheckoutOrigin      `json:"origin"`
		Desktop      CheckoutSubject     `json:"desktop"`
		Intent       uuid.UUID           `json:"intent"`
		ValidUntil   time.Time           `json:"validUntil"`
		Selection    *RefundSelection    `json:"refundSelection,omitempty"`
		Confirmation *RefundConfirmation `json:"refundConfirmation,omitempty"`
		Cancellation *RefundCancellation `json:"refundCancellation,omitempty"`
	}
	if len(raw) > 8192 || decodeGift(raw, &req) != nil {
		return nil, ErrCheckoutDenied
	}
	q := &CheckoutRequest{Version: req.Version, Origin: req.Origin, Desktop: req.Desktop, Intent: req.Intent, ValidUntil: req.ValidUntil,
		refundSelection: req.Selection, refundConfirmation: req.Confirmation, refundCancellation: req.Cancellation}
	if !q.validSession(s.Source, creation, intent) || (action == "refund_cancel") != (req.Cancellation != nil) {
		return nil, ErrCheckoutDenied
	}
	switch action {
	case "refund_quote":
		if !req.Selection.valid() || req.Confirmation != nil {
			return nil, ErrCheckoutDenied
		}
	case "refund_confirm":
		if req.Selection != nil || req.Confirmation == nil || req.Confirmation.Quote == uuid.Nil ||
			req.Confirmation.Quote == intent || !refundVersion.MatchString(req.Confirmation.BasisVersion) || req.Confirmation.Fen <= 0 {
			return nil, ErrCheckoutDenied
		}
	case "refund_status", "refund_quote_status":
		if req.Selection != nil || req.Confirmation != nil {
			return nil, ErrCheckoutDenied
		}
	case "refund_cancel":
		if req.Selection != nil || req.Confirmation != nil || req.Cancellation.Refund == uuid.Nil || req.Cancellation.Version < 1 {
			return nil, ErrCheckoutDenied
		}
	default:
		return nil, ErrCheckoutDenied
	}
	return q, nil
}

func validRefundBasis(basis string, units *string) bool {
	return basis == "unposted_cash" && units == nil || basis == "purchased_source" && units != nil && refundUnits.MatchString(*units) && *units != "0.00000000"
}
func (v CheckoutRefundQuote) valid(q *CheckoutRequest) bool {
	if v.Quote != q.Intent || !v.Selection.valid() || q.refundSelection != nil && !sameRefundSelection(v.Selection, q.refundSelection) {
		return false
	}
	if v.State == "expired" || v.State == "stale_quote" {
		return v.Fen == nil && v.Order == 0 && v.ExpiresAt == nil && v.Basis == "" && v.BasisVersion == "" && v.Currency == "" && v.Units == nil
	}
	if v.Order <= 0 || v.ExpiresAt == nil || v.ExpiresAt.IsZero() || !refundVersion.MatchString(v.BasisVersion) || (v.Basis != "purchased_source" && v.Basis != "unposted_cash") {
		return false
	}
	sel := v.Selection
	if sel.Order != v.Order || sel.Basis != v.Basis {
		return false
	}
	switch v.State {
	case "quoted":
		if v.Currency != "CNY" || v.Fen == nil || *v.Fen < 1 || !validRefundBasis(v.Basis, v.Units) {
			return false
		}
		return (sel.Fen == nil || *v.Fen == *sel.Fen) && (sel.Units == nil || v.Units != nil && *sel.Units == *v.Units)
	case "refund_pending", "recovery_review", "review", "insufficient", "below_minimum":
		return v.Fen == nil && v.Units == nil && v.Currency == ""
	}
	return false
}

func sameRefundSelection(left, right *RefundSelection) bool {
	equal := func(a, b *uuid.UUID) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
	return left.Order == right.Order && left.Basis == right.Basis && equal(left.Part, right.Part) && equal(left.Cutoff, right.Cutoff) &&
		(left.Units == nil && right.Units == nil || left.Units != nil && right.Units != nil && *left.Units == *right.Units) &&
		(left.Fen == nil && right.Fen == nil || left.Fen != nil && right.Fen != nil && *left.Fen == *right.Fen)
}
func (v CheckoutRefundDecision) valid(q *CheckoutRequest) bool {
	if c := q.refundCancellation; c != nil && (v.Refund == nil || *v.Refund != c.Refund || v.Phase == "held" || v.Version < c.Version) {
		return false
	}
	if v.Intent != q.Intent || v.Quote == uuid.Nil || q.refundConfirmation != nil && v.Quote != q.refundConfirmation.Quote {
		return false
	}
	if v.State == "recovery_review" && v.BasisVersion == "" {
		return v.Refund == nil && v.Order == 0 && v.Fen == 0 && v.Basis == "" && v.Phase == "" && v.Version == 0 && v.Units == nil && v.RefundOrder == ""
	}
	if v.Order <= 0 || v.Fen <= 0 || !refundVersion.MatchString(v.BasisVersion) || !validRefundBasis(v.Basis, v.Units) {
		return false
	}
	if f := q.refundConfirmation; f != nil && (f.BasisVersion != v.BasisVersion || f.Fen != v.Fen) {
		return false
	}
	if v.State == "accepted" {
		return v.Refund != nil && *v.Refund != uuid.Nil && v.RefundOrder == "R"+strings.ReplaceAll(v.Refund.String(), "-", "") && v.Version > 0 &&
			slices.Contains([]string{"held", "possibly_sent", "unknown", "cash_confirmed", "review", "settled", "released"}, v.Phase)
	}
	return v.Refund == nil && v.RefundOrder == "" && v.Phase == "" && v.Version == 0 &&
		slices.Contains([]string{"stale_quote", "expired", "quote_used", "refund_pending", "recovery_review", "review", "insufficient", "below_minimum"}, v.State)
}

/** memberRefundReceipt 先核对来源回应的原操作与金额，再呈交当前账号，现金终态沿原退款状态单独返回。 */
func memberRefundReceipt(receipt *CheckoutReceipt, q *CheckoutRequest, action, raw string) (*CheckoutReceipt, error) {
	receipt.Purpose, receipt.State = "refund", "observed"
	if action == "refund_quote" || action == "refund_quote_status" {
		var v CheckoutRefundQuote
		if decodeGift([]byte(raw), &v) != nil || !v.valid(q) {
			return nil, ErrMetonClosed
		}
		receipt.RefundQuote = &v
	} else {
		var v CheckoutRefundDecision
		if decodeGift([]byte(raw), &v) != nil || !v.valid(q) {
			return nil, ErrMetonClosed
		}
		receipt.RefundDecision = &v
	}
	return receipt, nil
}
