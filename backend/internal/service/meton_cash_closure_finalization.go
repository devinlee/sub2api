package service

import (
	"encoding/json"
	"github.com/google/uuid"
	"time"
)

/** 只读的最终关闭预查，不是账号已关闭或资金已结清的回执。 */
type CashClosureFinalization struct {
	Format          int                  `json:"format"`
	State           string               `json:"state"`
	Closure         uuid.UUID            `json:"closure"`
	Registration    uuid.UUID            `json:"registration"`
	ScopeHash       string               `json:"scopeHash"`
	Identity        *CashClosureDecision `json:"identity"`
	GiftEligibility uuid.UUID            `json:"giftEligibility"`
	Responsible     string               `json:"responsible"`
	Rights          string               `json:"rights"`
	Funds           string               `json:"funds"`
	ObservedAt      time.Time            `json:"observedAt"`
	ValidUntil      time.Time            `json:"validUntil"`
	Inventory       json.RawMessage      `json:"inventory"`
	Ready           int64                `json:"ready"`
	Pending         int64                `json:"pending"`
	Waiting         int64                `json:"waiting"`
	Meaning         string               `json:"meaning"`
}

func closureFinalizationValid(v CashClosureFinalization, q *CashClosureRefundRequest) bool {
	return v.Format == 1 && (v.State == "finalization_ready" || v.State == "refunds_pending") && (v.State == "finalization_ready") == (v.Ready == 0) &&
		v.Ready >= 0 && v.Pending >= 0 && v.Waiting >= 0 && v.Closure == q.Intent && v.Registration == q.Registration && v.ScopeHash == q.ScopeHash &&
		closureDecisionValid(v.Identity) && v.Identity.Decision == "closing" && q.Decision != nil && *v.Identity == *q.Decision &&
		q.GiftEligibility != nil && v.GiftEligibility == *q.GiftEligibility && closureAftercareResponsible.MatchString(v.Responsible) &&
		v.Rights == "retained_original_sources" && v.Funds == "not_declared_settled" && v.Meaning == "identity_final_decision_required" &&
		!v.ObservedAt.Before(time.Unix(0, 0)) && !v.ObservedAt.After(time.Now().Add(time.Minute)) && v.ValidUntil.After(v.ObservedAt) &&
		!v.ValidUntil.Before(q.ValidUntil.Add(-time.Microsecond)) && !v.ValidUntil.After(q.ValidUntil.Add(time.Microsecond)) &&
		v.ValidUntil.After(time.Now()) && closureAftercareInventory(v.Inventory)
}
