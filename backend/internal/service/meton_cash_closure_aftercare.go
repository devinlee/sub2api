package service

import (
	"encoding/json"
	"regexp"
	"time"

	"github.com/google/uuid"
)

var closureAftercareResponsible = regexp.MustCompile(`^[a-z0-9][a-z0-9._/-]{0,127}$`)

/** 最终身份与资金进度分开；本回执不含普通账号会话或可调用模型的凭据。 */
type CashClosureAftercare struct {
	Format        int                  `json:"format"`
	State         string               `json:"state"`
	Closure       uuid.UUID            `json:"closure"`
	Registration  uuid.UUID            `json:"registration"`
	ScopeHash     string               `json:"scopeHash"`
	IdentityEvent uuid.UUID            `json:"identityEvent"`
	Identity      *CashClosureDecision `json:"identity"`
	RecordedAt    time.Time            `json:"recordedAt"`
	Responsible   string               `json:"responsible"`
	Rights        string               `json:"rights"`
	Funds         string               `json:"funds"`
	Opening       json.RawMessage      `json:"opening"`
	Current       json.RawMessage      `json:"current"`
}

/** closing 与 withdrawn 不接收最终事实字段；closed 缺原事件或原资格时不能继续。 */
func closureDecisionValid(d *CashClosureDecision) bool {
	if d == nil || d.Closure == uuid.Nil || d.Registration == uuid.Nil || d.SecurityVersion < 2 || d.RecoveryVersion < 1 ||
		d.LastStopVersion < 2 || d.LastStopVersion > d.SecurityVersion {
		return false
	}
	if d.Decision == "closed" {
		return d.Lifecycle == "closed" && d.LastStopVersion == d.SecurityVersion && d.IdentityEvent != nil && *d.IdentityEvent != uuid.Nil &&
			d.Revision != nil && *d.Revision >= 3 && d.ClosedAt != nil && !d.ClosedAt.Before(time.Unix(0, 0)) && !d.ClosedAt.After(time.Now()) &&
			d.GiftEligibility != nil && *d.GiftEligibility != uuid.Nil
	}
	return d.IdentityEvent == nil && d.Revision == nil && d.ClosedAt == nil && d.GiftEligibility == nil &&
		(d.Decision == "closing" && d.Lifecycle == "closing" || d.Decision == "withdrawn" && (d.Lifecycle == "security_recovery" || d.Lifecycle == "active"))
}

func sameFinalClosure(a, b *CashClosureDecision) bool {
	return closureDecisionValid(a) && closureDecisionValid(b) && a.Decision == "closed" && b.Decision == "closed" &&
		a.Closure == b.Closure && a.Registration == b.Registration && a.SecurityVersion == b.SecurityVersion && a.RecoveryVersion == b.RecoveryVersion &&
		a.LastStopVersion == b.LastStopVersion && *a.IdentityEvent == *b.IdentityEvent && *a.Revision == *b.Revision &&
		a.ClosedAt.Equal(*b.ClosedAt) && *a.GiftEligibility == *b.GiftEligibility
}

/** 原生端先验证固定头和分类截点；来源金额等式继续由同一来源权威及 Meton 严格适配复核。 */
func closureAftercareInventory(raw json.RawMessage) bool {
	var v struct {
		Format        int                        `json:"format"`
		Funds         map[string]json.RawMessage `json:"funds"`
		Cut           map[string]json.RawMessage `json:"cut"`
		InventoryHash string                     `json:"inventoryHash"`
		Count         int64                      `json:"count"`
		Categories    map[string]int64           `json:"categories"`
		Meaning       string                     `json:"meaning"`
	}
	if decodeGift(raw, &v) != nil || v.Format != 1 || v.Count < 0 || !refundVersion.MatchString(v.InventoryHash) ||
		v.Meaning != "inspection_only_not_settled" || len(v.Funds) == 0 || len(v.Cut) != 3 || v.Categories == nil {
		return false
	}
	var count int64
	for name, n := range v.Categories {
		if name == "" || n < 1 || n > v.Count-count {
			return false
		}
		count += n
	}
	return count == v.Count
}

func closureAftercareValid(v CashClosureAftercare, q *CashClosureRefundRequest) bool {
	d := v.Identity
	return v.Format == 1 && v.State == "aftercare_open" && v.Closure == q.Intent && v.Registration == q.Registration && v.ScopeHash == q.ScopeHash &&
		closureDecisionValid(d) && d.Decision == "closed" && d.Closure == q.Intent && d.Registration == q.Registration &&
		v.IdentityEvent == *d.IdentityEvent && !v.RecordedAt.Before(*d.ClosedAt) && !v.RecordedAt.After(time.Now().Add(time.Minute)) &&
		closureAftercareResponsible.MatchString(v.Responsible) && v.Rights == "retained_original_sources" && v.Funds == "not_declared_settled" &&
		(q.Decision == nil || sameFinalClosure(q.Decision, d)) && closureAftercareInventory(v.Opening) && closureAftercareInventory(v.Current)
}
