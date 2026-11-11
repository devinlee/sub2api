package service

import (
	"time"

	"github.com/google/uuid"
)

var closureRefundActions = [...]string{"closure_refund_admit", "closure_refund_stop", "closure_refunds"}

/** IsCheckoutClosureRefund 将后台原范围结清与会员退款的会话权限分开。 */
func IsCheckoutClosureRefund(action string) bool {
	return action == "closure_refund_admit" || action == "closure_refund_stop" || action == "closure_refunds"
}

type CashClosureDecision struct {
	Closure         uuid.UUID  `json:"closure"`
	Registration    uuid.UUID  `json:"registration"`
	Decision        string     `json:"decision"`
	Lifecycle       string     `json:"lifecycle"`
	SecurityVersion int64      `json:"securityVersion"`
	RecoveryVersion int64      `json:"recoveryVersion"`
	LastStopVersion int64      `json:"lastStopVersion"`
	IdentityEvent   *uuid.UUID `json:"identityEvent,omitempty"`
	Revision        *int64     `json:"revision,omitempty"`
	ClosedAt        *time.Time `json:"closedAt,omitempty"`
	GiftEligibility *uuid.UUID `json:"giftEligibility,omitempty"`
}
type CashClosureRefundTarget struct {
	Order  int64      `json:"order,string"`
	Part   *uuid.UUID `json:"part,omitempty"`
	Cutoff *uuid.UUID `json:"cutoff,omitempty"`
	Basis  string     `json:"basis"`
}
type CashClosureRefundRequest struct {
	Version         int                      `json:"version"`
	Origin          CheckoutOrigin           `json:"origin"`
	Intent          uuid.UUID                `json:"intent"`
	Registration    uuid.UUID                `json:"registration"`
	SourceSystem    string                   `json:"sourceSystem"`
	ScopeHash       string                   `json:"scopeHash"`
	Decision        *CashClosureDecision     `json:"decision,omitempty"`
	Operation       *uuid.UUID               `json:"operation,omitempty"`
	Target          *CashClosureRefundTarget `json:"target,omitempty"`
	Targets         *bool                    `json:"targets,omitempty"`
	Aftercare       *bool                    `json:"aftercare,omitempty"`
	Finalization    *bool                    `json:"finalization,omitempty"`
	GiftEligibility *uuid.UUID               `json:"giftEligibility,omitempty"`
	Cursor          *string                  `json:"cursor,omitempty"`
	After           *int64                   `json:"after,omitempty"`
	Limit           *int                     `json:"limit,omitempty"`
	ValidUntil      time.Time                `json:"validUntil"`
}
type CashClosureRefundAdmission struct {
	State     string     `json:"state"`
	Closure   uuid.UUID  `json:"closure"`
	Operation uuid.UUID  `json:"operation"`
	Order     int64      `json:"order"`
	Part      *uuid.UUID `json:"part"`
	Cutoff    *uuid.UUID `json:"cutoff"`
	Basis     string     `json:"basis"`
	Refund    *uuid.UUID `json:"refund"`
	Quote     *uuid.UUID `json:"quote"`
	Fen       int64      `json:"fen"`
	Units     *string    `json:"units"`
}
type CashClosureRefundControl struct {
	Closure   uuid.UUID  `json:"closure"`
	State     string     `json:"state"`
	OpenedAt  *time.Time `json:"openedAt"`
	StoppedAt *time.Time `json:"stoppedAt"`
	Cut       *int64     `json:"cut"`
	Count     *int64     `json:"count"`
}
type CashClosureRefundAttempt struct {
	Sequence      int64                      `json:"sequence"`
	Operation     uuid.UUID                  `json:"operation"`
	Receipt       CashClosureRefundAdmission `json:"receipt"`
	RefundPhase   *string                    `json:"refundPhase"`
	RefundVersion *int64                     `json:"refundVersion"`
}
type CashClosureRefundPage struct {
	Control CashClosureRefundControl   `json:"control"`
	Cut     int64                      `json:"cut"`
	After   int64                      `json:"after"`
	Items   []CashClosureRefundAttempt `json:"items"`
	HasMore bool                       `json:"hasMore"`
}

/** 返回来源已持久的事实；已停止仅表示不会再自动受理，已有退款仍按原笔推进。 */
type CashClosureRefundResult struct {
	Version      int                         `json:"version"`
	Origin       CheckoutOrigin              `json:"origin"`
	Registration uuid.UUID                   `json:"registration"`
	Reference    uuid.UUID                   `json:"reference"`
	SourceSystem string                      `json:"sourceSystem"`
	ScopeHash    string                      `json:"scopeHash"`
	Admission    *CashClosureRefundAdmission `json:"admission"`
	Control      *CashClosureRefundControl   `json:"control"`
	Operation    *CashClosureRefundAttempt   `json:"operation"`
	Page         *CashClosureRefundPage      `json:"page"`
	Targets      *CashClosureTargets         `json:"targets,omitempty"`
	Aftercare    *CashClosureAftercare       `json:"aftercare,omitempty"`
	Finalization *CashClosureFinalization    `json:"finalization,omitempty"`
}

func closureRefundTargetValid(order int64, part, cutoff *uuid.UUID, basis string) bool {
	return order > 0 && (part == nil) != (cutoff == nil) && (part == nil || *part != uuid.Nil) && (cutoff == nil || *cutoff != uuid.Nil) &&
		(basis == "purchased_source" || basis == "unposted_cash")
}
func sameClosureRefundTarget(v CashClosureRefundAdmission, target *CashClosureRefundTarget) bool {
	equal := func(a, b *uuid.UUID) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
	return target != nil && v.Order == target.Order && v.Basis == target.Basis && equal(v.Part, target.Part) && equal(v.Cutoff, target.Cutoff)
}

/** 严格区分原操作查询与分页；只读请求不能携带新的 Identity 执行决定。 */
func (s *MetonCheckout) parseCashClosureRefund(raw []byte, action string, creation, closure uuid.UUID) (*CheckoutRequest, error) {
	var q CashClosureRefundRequest
	if len(raw) > 8192 || decodeGift(raw, &q) != nil {
		return nil, ErrCheckoutDenied
	}
	o, now := q.Origin, time.Now()
	if q.Version != 1 || q.Intent != closure || closure == uuid.Nil || creation == uuid.Nil || o.Creation != creation || q.Registration == uuid.Nil ||
		!closureSystem.MatchString(q.SourceSystem) || !refundVersion.MatchString(q.ScopeHash) || o.Environment != s.Source.Environment ||
		o.Source != s.Source.Source || o.Epoch != s.Source.Epoch || o.User == uuid.Nil || o.Account == uuid.Nil || o.Dispatch == uuid.Nil ||
		o.SourceMarker == uuid.Nil || o.RemoteUser < 1 || !q.ValidUntil.After(now) || q.ValidUntil.After(now.Add(30*time.Second)) {
		return nil, ErrCheckoutDenied
	}
	if q.Finalization != nil {
		if action != "closure_refunds" || !*q.Finalization || q.GiftEligibility == nil || *q.GiftEligibility == uuid.Nil ||
			q.Aftercare != nil || q.Operation != nil || q.Target != nil || q.Targets != nil || q.Cursor != nil || q.After != nil || q.Limit != nil ||
			!closureDecisionValid(q.Decision) || q.Decision.Decision != "closing" || q.Decision.Closure != closure || q.Decision.Registration != q.Registration {
			return nil, ErrCheckoutDenied
		}
	} else if q.GiftEligibility != nil {
		return nil, ErrCheckoutDenied
	} else if action == "closure_refunds" {
		if q.Decision != nil || q.Target != nil {
			return nil, ErrCheckoutDenied
		}
		if q.Aftercare != nil {
			if !*q.Aftercare || q.Operation != nil || q.Targets != nil || q.Cursor != nil || q.After != nil || q.Limit != nil {
				return nil, ErrCheckoutDenied
			}
		} else if q.Targets != nil {
			if !*q.Targets || q.Operation != nil || q.After != nil || q.Limit == nil || *q.Limit < 1 || *q.Limit > 100 ||
				q.Cursor != nil && !closureTargetCursor.MatchString(*q.Cursor) {
				return nil, ErrCheckoutDenied
			}
		} else if q.Cursor != nil {
			return nil, ErrCheckoutDenied
		} else if q.Operation != nil {
			if *q.Operation == uuid.Nil || q.After != nil || q.Limit != nil {
				return nil, ErrCheckoutDenied
			}
		} else if q.After == nil || *q.After < 0 || q.Limit == nil || *q.Limit < 1 || *q.Limit > 100 {
			return nil, ErrCheckoutDenied
		}
	} else {
		d := q.Decision
		if q.Targets != nil || q.Cursor != nil || q.After != nil || q.Limit != nil || !closureDecisionValid(d) || d.Closure != closure || d.Registration != q.Registration {
			return nil, ErrCheckoutDenied
		}
		if action == "closure_refund_admit" {
			if q.Aftercare != nil {
				if !*q.Aftercare || d.Decision != "closed" || q.Operation != nil || q.Target != nil {
					return nil, ErrCheckoutDenied
				}
			} else if (d.Decision != "closing" && d.Decision != "closed") || q.Operation == nil || *q.Operation == uuid.Nil || q.Target == nil ||
				!closureRefundTargetValid(q.Target.Order, q.Target.Part, q.Target.Cutoff, q.Target.Basis) {
				return nil, ErrCheckoutDenied
			}
		} else if q.Aftercare != nil || action != "closure_refund_stop" || d.Decision != "withdrawn" || (d.Lifecycle != "security_recovery" && d.Lifecycle != "active") ||
			q.Operation != nil || q.Target != nil {
			return nil, ErrCheckoutDenied
		}
	}
	return &CheckoutRequest{Version: 1, Origin: o, Intent: closure, ValidUntil: q.ValidUntil, cashClosureRefund: &q}, nil
}

func closureRefundAdmissionValid(v CashClosureRefundAdmission, closure, operation uuid.UUID) bool {
	if v.Closure != closure || v.Operation == uuid.Nil || v.Operation != operation {
		return false
	}
	if v.State == "stopped" {
		return v.Order == 0 && v.Part == nil && v.Cutoff == nil && v.Basis == "" && v.Refund == nil && v.Quote == nil && v.Fen == 0 && v.Units == nil
	}
	if !closureRefundTargetValid(v.Order, v.Part, v.Cutoff, v.Basis) {
		return false
	}
	if v.State == "accepted" {
		return v.Refund != nil && *v.Refund != uuid.Nil && v.Quote != nil && *v.Quote != uuid.Nil && v.Fen > 0 && validRefundBasis(v.Basis, v.Units)
	}
	if v.Quote != nil || v.Fen != 0 || v.Units != nil {
		return false
	}
	if v.State == "existing_refund" {
		return v.Refund != nil && *v.Refund != uuid.Nil
	}
	if v.Refund != nil {
		return false
	}
	switch v.State {
	case "recheck_required", "recovery_review", "review", "below_minimum", "insufficient":
		return true
	}
	return false
}
func closureRefundControlValid(v CashClosureRefundControl, closure uuid.UUID) bool {
	validTime := func(t *time.Time) bool {
		return t == nil || !t.Before(time.Unix(0, 0)) && !t.After(time.Now().Add(time.Minute))
	}
	if v.Closure != closure || !validTime(v.OpenedAt) || !validTime(v.StoppedAt) {
		return false
	}
	if v.State == "running" {
		return v.OpenedAt != nil && v.StoppedAt == nil && v.Cut == nil && v.Count == nil
	}
	return v.State == "stopped" && v.StoppedAt != nil && v.Cut != nil && *v.Cut >= 0 && v.Count != nil && *v.Count >= 0 && *v.Count <= *v.Cut &&
		((*v.Count == 0) == (*v.Cut == 0)) && (v.OpenedAt == nil || !v.OpenedAt.After(*v.StoppedAt))
}
func closureRefundAttemptValid(v CashClosureRefundAttempt, closure uuid.UUID) bool {
	if v.Sequence < 1 || !closureRefundAdmissionValid(v.Receipt, closure, v.Operation) || v.Receipt.State == "stopped" {
		return false
	}
	if v.Receipt.Refund == nil {
		return v.RefundPhase == nil && v.RefundVersion == nil
	}
	if v.RefundPhase == nil || v.RefundVersion == nil || *v.RefundVersion < 1 {
		return false
	}
	switch *v.RefundPhase {
	case "held", "possibly_sent", "unknown", "cash_confirmed", "review", "settled", "released":
		return true
	}
	return false
}

/** 来源回执先核原归属、固定截点和连续递增序号，再交业务协调；不转发任意 JSON 为完成结论。 */
func cashClosureRefundReceipt(receipt *CheckoutReceipt, request *CheckoutRequest, action, state string) (*CheckoutReceipt, error) {
	q := request.cashClosureRefund
	if q == nil || len(state) > 1048576 {
		return nil, ErrMetonClosed
	}
	r := &CashClosureRefundResult{Version: 1, Origin: q.Origin, Registration: q.Registration, Reference: q.Intent, SourceSystem: q.SourceSystem, ScopeHash: q.ScopeHash}
	if q.Finalization != nil && *q.Finalization {
		var v CashClosureFinalization
		if decodeGift([]byte(state), &v) != nil || !closureFinalizationValid(v, q) {
			return nil, ErrMetonClosed
		}
		r.Finalization = &v
		receipt.ClosureRefund = r
		return receipt, nil
	}
	if q.Aftercare != nil && *q.Aftercare {
		var v CashClosureAftercare
		if decodeGift([]byte(state), &v) != nil || !closureAftercareValid(v, q) {
			return nil, ErrMetonClosed
		}
		r.Aftercare = &v
		receipt.ClosureRefund = r
		return receipt, nil
	}
	switch action {
	case "closure_refund_admit":
		var v CashClosureRefundAdmission
		if decodeGift([]byte(state), &v) != nil || q.Operation == nil || !closureRefundAdmissionValid(v, q.Intent, *q.Operation) ||
			v.State != "stopped" && !sameClosureRefundTarget(v, q.Target) {
			return nil, ErrMetonClosed
		}
		r.Admission = &v
	case "closure_refund_stop":
		var v CashClosureRefundControl
		if decodeGift([]byte(state), &v) != nil || !closureRefundControlValid(v, q.Intent) || v.State != "stopped" {
			return nil, ErrMetonClosed
		}
		r.Control = &v
	case "closure_refunds":
		if q.Targets != nil && *q.Targets {
			var v CashClosureTargets
			if decodeGift([]byte(state), &v) != nil || !closureTargetsValid(v, q) {
				return nil, ErrMetonClosed
			}
			r.Targets = &v
		} else if q.Operation != nil {
			var v CashClosureRefundAttempt
			if decodeGift([]byte(state), &v) != nil || !closureRefundAttemptValid(v, q.Intent) || v.Operation != *q.Operation {
				return nil, ErrMetonClosed
			}
			r.Operation = &v
		} else {
			var v CashClosureRefundPage
			if decodeGift([]byte(state), &v) != nil || !closureRefundControlValid(v.Control, q.Intent) || q.After == nil || q.Limit == nil ||
				v.After != *q.After || v.Cut < 0 || v.After > v.Cut || v.Items == nil || len(v.Items) > *q.Limit ||
				v.Control.Cut != nil && *v.Control.Cut != v.Cut {
				return nil, ErrMetonClosed
			}
			previous := v.After
			seen := map[uuid.UUID]bool{}
			for _, item := range v.Items {
				if !closureRefundAttemptValid(item, q.Intent) || item.Sequence <= previous || item.Sequence > v.Cut || seen[item.Operation] {
					return nil, ErrMetonClosed
				}
				previous = item.Sequence
				seen[item.Operation] = true
			}
			if v.HasMore && len(v.Items) == 0 || v.HasMore != (previous < v.Cut) {
				return nil, ErrMetonClosed
			}
			r.Page = &v
		}
	default:
		return nil, ErrMetonClosed
	}
	receipt.ClosureRefund = r
	return receipt, nil
}
