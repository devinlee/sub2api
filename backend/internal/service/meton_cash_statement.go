package service

import (
	"bytes"
	"context"
	"encoding/json"
	"math/big"
	"reflect"
	"regexp"
	"time"

	"github.com/google/uuid"
)

type CashStatementIdentity struct {
	Lifecycle       string `json:"lifecycle"`
	SecurityVersion int64  `json:"securityVersion"`
	RecoveryVersion int64  `json:"recoveryVersion"`
	LastStopVersion int64  `json:"lastStopVersion"`
}

/** 本人和原关闭售后是不同查询用途；普通登录不能带原关闭编号扩大权限。 */
type CashStatementAudience struct {
	Kind         string                 `json:"kind"`
	Registration uuid.UUID              `json:"registration"`
	Identity     *CashStatementIdentity `json:"identity,omitempty"`
	Closure      *uuid.UUID             `json:"closure,omitempty"`
	Scope        *string                `json:"scope,omitempty"`
}
type CashStatementRequest struct {
	Scope        MetonStatementScope   `json:"scope"`
	SourceSystem string                `json:"sourceSystem"`
	Audience     CashStatementAudience `json:"audience"`
	From         string                `json:"from"`
	Through      string                `json:"through"`
	Cut          *string               `json:"cut"`
	After        int64                 `json:"after"`
	Size         int                   `json:"size"`
}
type MetonCashStatementStore interface {
	CashStatement(context.Context, MetonManagedSource, CashStatementRequest) (json.RawMessage, error)
}
type combinedStatementStore interface {
	MetonStatementStore
	MetonCashStatementStore
}

/** 只在组合方已核对新增只读函数和显式开关后建立，不给现有普通账单自动扩权。 */
func NewMetonStatementsWithCash(store combinedStatementStore) *MetonStatements {
	if store == nil {
		return nil
	}
	return &MetonStatements{store: store, cash: store}
}
func ReadCashStatementRequest(raw []byte, q *CashStatementRequest) error {
	return decodeStatement(raw, q)
}
func (s MetonManagedSource) ValidCashStatement(q CashStatementRequest) bool {
	if !closureSystem.MatchString(q.SourceSystem) || !s.ValidStatement(MetonStatementRequest{Scope: q.Scope, From: q.From, Through: q.Through}) ||
		q.After < 0 || q.Size < 1 || q.Size > 100 || q.Cut == nil && q.After != 0 || q.Cut != nil && !cashStatementDigest.MatchString(*q.Cut) {
		return false
	}
	a := q.Audience
	if a.Registration == uuid.Nil {
		return false
	}
	if a.Kind == "account" {
		return a.Identity != nil && a.Closure == nil && a.Scope == nil && a.Identity.Lifecycle == "active" &&
			a.Identity.SecurityVersion > 0 && a.Identity.RecoveryVersion > 0 && a.Identity.LastStopVersion >= 0
	}
	return a.Kind == "aftercare" && a.Identity == nil && a.Closure != nil && *a.Closure != uuid.Nil && a.Scope != nil && cashStatementDigest.MatchString(*a.Scope)
}

/** 来源前后都核对当前只读身份。截点变化交回同步状态，不伪造付款失败，也不重发现金请求。 */
func (s *MetonStatements) ReadCash(ctx context.Context, source MetonManagedSource, q CashStatementRequest) (json.RawMessage, error) {
	live, ok := MetonSource()
	key, enabled := source.StatementKeyID()
	if s == nil || s.cash == nil || !ok || live != source || !enabled || !source.ValidCashStatement(q) {
		return nil, ErrMetonClosed
	}
	raw, err := s.cash.CashStatement(ctx, source, q)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw) > 196608 {
		return nil, ErrMetonClosed
	}
	var result cashStatementEnvelope
	if decodeStatement(raw, &result) != nil || !result.matches(q) {
		return nil, ErrMetonClosed
	}
	live, ok = MetonSource()
	now, enabled := source.StatementKeyID()
	if !ok || live != source || !enabled || now != key || ctx.Err() != nil {
		return nil, ErrMetonClosed
	}
	return raw, nil
}

var cashStatementDigest = regexp.MustCompile(`^[a-f0-9]{64}$`)
var cashStatementFen = regexp.MustCompile(`^(0|[1-9][0-9]{0,37})$`)

type CashStatementOrigin struct {
	Environment  string    `json:"environment"`
	Source       string    `json:"source"`
	Epoch        int64     `json:"epoch"`
	User         uuid.UUID `json:"user"`
	Account      uuid.UUID `json:"account"`
	Creation     uuid.UUID `json:"creation"`
	Dispatch     uuid.UUID `json:"dispatch"`
	RemoteUser   int64     `json:"remote_user"`
	SourceMarker uuid.UUID `json:"source_marker"`
	SourceSystem string    `json:"source_system"`
}

/** 内部原归属仅交给窄来源门面，公开 BillingProjection 另去掉供应端标识。 */
func (q CashStatementRequest) Origin() CashStatementOrigin {
	c := q.Scope
	return CashStatementOrigin{c.Environment, c.Source, c.Epoch, c.User, c.Account, c.Operation, c.Dispatch, c.RemoteUser, c.SourceMarker, q.SourceSystem}
}

type cashStatementTotals struct {
	Scope                    string `json:"scope"`
	Currency                 string `json:"currency"`
	PaymentRecordedFen       string `json:"paymentRecordedFen"`
	PurchaseAllocatedFen     string `json:"purchaseAllocatedFen"`
	UnpostedAllocatedFen     string `json:"unpostedAllocatedFen"`
	UnallocatedFen           string `json:"unallocatedFen"`
	RefundConfirmedFen       string `json:"refundConfirmedFen"`
	RefundSourceSettledFen   string `json:"refundSourceSettledFen"`
	RefundAwaitingSourceFen  string `json:"refundAwaitingSourceFen"`
	RefundPendingFen         string `json:"refundPendingFen"`
	UnpostedRefundPendingFen string `json:"unpostedRefundPendingFen"`
	HistoricalOrders         int64  `json:"historicalOrders"`
	UnmappedOrders           int64  `json:"unmappedOrders"`
	ExternalReviews          int64  `json:"externalReviews"`
	Disputes                 int64  `json:"disputes"`
}

func (v *cashStatementTotals) valid() bool {
	if v == nil || v.Scope != "recorded_cash_facts" || v.Currency != "CNY" || v.HistoricalOrders < 0 || v.UnmappedOrders < 0 || v.ExternalReviews < 0 || v.Disputes < 0 {
		return false
	}
	values := []string{v.PaymentRecordedFen, v.PurchaseAllocatedFen, v.UnpostedAllocatedFen, v.UnallocatedFen, v.RefundConfirmedFen,
		v.RefundSourceSettledFen, v.RefundAwaitingSourceFen, v.RefundPendingFen, v.UnpostedRefundPendingFen}
	var n []*big.Int
	for _, value := range values {
		if !cashStatementFen.MatchString(value) {
			return false
		}
		parsed, ok := new(big.Int).SetString(value, 10)
		if !ok {
			return false
		}
		n = append(n, parsed)
	}
	return n[0].Cmp(new(big.Int).Add(new(big.Int).Add(n[1], n[2]), n[3])) == 0 &&
		n[4].Cmp(new(big.Int).Add(n[5], n[6])) == 0 && n[8].Cmp(n[7]) <= 0
}

type cashStatementClosure struct {
	Operation uuid.UUID `json:"operation"`
	State     string    `json:"state"`
	Funds     string    `json:"funds"`
	Scope     string    `json:"scope"`
}
type cashStatementItem struct {
	Ordinal int64                      `json:"ordinal"`
	Kind    string                     `json:"kind"`
	Ref     string                     `json:"ref"`
	Value   map[string]json.RawMessage `json:"value"`
}
type cashStatementEnvelope struct {
	Format     int                   `json:"format"`
	State      string                `json:"state"`
	Origin     CashStatementOrigin   `json:"origin"`
	Audience   CashStatementAudience `json:"audience"`
	From       *string               `json:"from"`
	Through    *string               `json:"through"`
	Ledger     json.RawMessage       `json:"ledger"`
	Cash       *cashStatementTotals  `json:"cash"`
	Closure    *cashStatementClosure `json:"closure"`
	Count      *int64                `json:"count"`
	Cut        *string               `json:"cut"`
	ObservedAt *time.Time            `json:"observedAt"`
	After      *int64                `json:"after"`
	Size       *int                  `json:"size"`
	Next       *int64                `json:"next"`
	More       *bool                 `json:"more"`
	Items      []cashStatementItem   `json:"items"`
}

func (v cashStatementEnvelope) matches(q CashStatementRequest) bool {
	if v.Format != 1 || v.Origin != q.Origin() || !reflect.DeepEqual(v.Audience, q.Audience) {
		return false
	}
	if v.State == "snapshot_changed" {
		return q.Cut != nil && v.From == nil && v.Through == nil && v.Ledger == nil && v.Cash == nil && v.Closure == nil && v.Count == nil &&
			v.Cut == nil && v.ObservedAt == nil && v.After == nil && v.Size == nil && v.Next == nil && v.More == nil && v.Items == nil
	}
	if v.State != "observed" || v.From == nil || *v.From != q.From || v.Through == nil || *v.Through != q.Through ||
		v.Cut == nil || !cashStatementDigest.MatchString(*v.Cut) || q.Cut != nil && *v.Cut != *q.Cut ||
		v.ObservedAt == nil || v.ObservedAt.Before(time.Unix(0, 0)) || v.ObservedAt.After(time.Now().Add(time.Minute)) ||
		v.Count == nil || *v.Count < 0 || v.After == nil || *v.After != q.After || v.Size == nil || *v.Size != q.Size ||
		v.Next == nil || *v.Next < q.After || *v.Next > *v.Count || v.More == nil || *v.More != (*v.Next < *v.Count) ||
		v.Items == nil || len(v.Items) > q.Size || *v.Next-q.After != int64(len(v.Items)) || *v.More && len(v.Items) != q.Size || !v.Cash.valid() {
		return false
	}
	if q.Audience.Kind == "account" {
		var ledger statementEnvelope
		if v.Closure != nil || decodeStatement(v.Ledger, &ledger) != nil || !ledger.matches(MetonStatementRequest{Scope: q.Scope, From: q.From, Through: q.Through}) ||
			!ledger.Cut.ObservedAt.Equal(*v.ObservedAt) {
			return false
		}
	} else if !bytes.Equal(bytes.TrimSpace(v.Ledger), []byte("null")) || v.Closure == nil ||
		v.Closure.Operation != *q.Audience.Closure || v.Closure.Scope != *q.Audience.Scope || v.Closure.State != "closed" || v.Closure.Funds != "aftercare_open" {
		return false
	}
	seen := map[string]bool{}
	for i, item := range v.Items {
		if item.Ordinal != q.After+int64(i)+1 || len(item.Ref) == 0 || len(item.Ref) > 160 || item.Value == nil || seen[item.Kind+"/"+item.Ref] {
			return false
		}
		switch item.Kind {
		case "source", "registration", "order", "payment", "cash_basis", "legacy_order", "legacy_basis", "legacy_activity",
			"legacy_refund_audit", "unmapped_order", "refund", "model", "cash_review", "dispute":
		default:
			return false
		}
		var category string
		if json.Unmarshal(item.Value["category"], &category) != nil || category == "" {
			return false
		}
		seen[item.Kind+"/"+item.Ref] = true
	}
	return true
}
