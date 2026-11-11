package service

import (
	"fmt"
	"regexp"

	"github.com/google/uuid"
)

var closureTargetCursor = regexp.MustCompile(`^[0-9]{20}/[ml]/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[pu]$`)

type CashClosureTarget struct {
	Cursor       string                    `json:"cursor"`
	Order        int64                     `json:"order"`
	Part         *uuid.UUID                `json:"part"`
	Cutoff       *uuid.UUID                `json:"cutoff"`
	Basis        string                    `json:"basis"`
	State        string                    `json:"state"`
	Availability string                    `json:"availability"`
	Operation    *uuid.UUID                `json:"operation"`
	Previous     *CashClosureRefundAttempt `json:"previous"`
}
type CashClosureTargets struct {
	Control *CashClosureRefundControl `json:"control"`
	After   *string                   `json:"after"`
	Items   []CashClosureTarget       `json:"items"`
	HasMore bool                      `json:"hasMore"`
}

/** 查询只返回原范围和原受理事实；候选操作不代表已受理或已退款。 */
func closureTargetsValid(v CashClosureTargets, q *CashClosureRefundRequest) bool {
	if q.Limit == nil || v.Items == nil || len(v.Items) > *q.Limit || (v.After == nil) != (q.Cursor == nil) ||
		v.After != nil && *v.After != *q.Cursor || v.HasMore && len(v.Items) != *q.Limit ||
		v.Control != nil && !closureRefundControlValid(*v.Control, q.Intent) {
		return false
	}
	after := ""
	if q.Cursor != nil {
		after = *q.Cursor
	}
	for _, item := range v.Items {
		if !closureRefundTargetValid(item.Order, item.Part, item.Cutoff, item.Basis) || item.Cursor <= after {
			return false
		}
		kind, id, basis := "m", item.Part, "p"
		if item.Cutoff != nil {
			kind, id = "l", item.Cutoff
		}
		if item.Basis == "unposted_cash" {
			basis = "u"
		}
		if item.Cursor != fmt.Sprintf("%020d/%s/%s/%s", item.Order, kind, id.String(), basis) {
			return false
		}
		if item.Previous != nil && (!closureRefundAttemptValid(*item.Previous, q.Intent) ||
			!sameClosureRefundTarget(item.Previous.Receipt, &CashClosureRefundTarget{Order: item.Order, Part: item.Part, Cutoff: item.Cutoff, Basis: item.Basis})) {
			return false
		}
		switch item.Availability {
		case "quoted", "refund_pending", "recovery_review", "review", "below_minimum", "insufficient":
		default:
			return false
		}
		pending := item.Previous != nil && item.Previous.Receipt.Refund != nil && item.Previous.RefundPhase != nil &&
			*item.Previous.RefundPhase != "settled" && *item.Previous.RefundPhase != "released"
		stopped := v.Control != nil && v.Control.State == "stopped"
		switch item.State {
		case "ready":
			if stopped || pending || item.Operation == nil || *item.Operation == uuid.Nil ||
				item.Previous != nil && *item.Operation == item.Previous.Operation ||
				item.Availability != "quoted" && item.Availability != "refund_pending" {
				return false
			}
		case "pending":
			if stopped || !pending || item.Operation == nil || *item.Operation != item.Previous.Operation {
				return false
			}
		case "waiting":
			if stopped || pending || item.Operation != nil || item.Availability == "quoted" || item.Availability == "refund_pending" {
				return false
			}
		case "stopped":
			if !stopped || item.Operation != nil {
				return false
			}
		default:
			return false
		}
		after = item.Cursor
	}
	return true
}
