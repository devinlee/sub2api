package service

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

/** 人员由 Meton 当前权威核验；本端只接受独立服务身份交来的有界原意图，不接会员身份或金额。 */
type CashOriginalRetryCommand struct {
	Format        int       `json:"format"`
	Operation     uuid.UUID `json:"operation"`
	OriginalKey   string    `json:"originalKey"`
	BasisDigest   string    `json:"basisDigest"`
	Person        uuid.UUID `json:"person"`
	PersonVersion int64     `json:"personVersion"`
	Role          string    `json:"role"`
	IntentDigest  string    `json:"intentDigest"`
	Until         time.Time `json:"until"`
}
type CashOriginalRetryRequest struct {
	Version     int                      `json:"version"`
	Environment string                   `json:"environment"`
	Source      string                   `json:"source"`
	Epoch       int64                    `json:"epoch"`
	ScopeKey    string                   `json:"scopeKey"`
	Command     CashOriginalRetryCommand `json:"command"`
}
type CashOriginalRetryStore interface {
	RetryCashOriginal(context.Context, CashOriginalRetryCommand, string) (json.RawMessage, error)
}

/** 与列表、本人退款及后台执行身份隔离；普通构建始终关闭。 */
func (s MetonManagedSource) CashOriginalRetryKeyID() (string, bool) {
	return independentCashReadKey("METON_MANAGED_CASH_ORIGINAL_RETRY_KEY_ID")
}
func ReadCashOriginalRetryRequest(raw []byte, q *CashOriginalRetryRequest) error {
	return decodeStatement(raw, q)
}

/** 原键必须完整且规范，截止时间来自当前人员证明，不能在转发时无限延长。 */
func (s MetonManagedSource) ValidCashOriginalRetry(q CashOriginalRetryRequest, action string) bool {
	c := q.Command
	if q.Version != 1 || q.Environment != s.Environment || q.Source != s.Source || q.Epoch != s.Epoch ||
		!cashStatementDigest.MatchString(q.ScopeKey) || c.Format != 1 || c.Operation == uuid.Nil || c.Person == uuid.Nil ||
		c.PersonVersion <= 0 || c.PersonVersion > 999999999999999999 || !cashStatementDigest.MatchString(c.BasisDigest) ||
		!cashStatementDigest.MatchString(c.IntentDigest) || !c.Until.After(time.Now()) || c.Until.After(time.Now().Add(30*time.Second)) ||
		(action != "retry" && action != "result") || (c.Role != "intake" && c.Role != "reviewer" && !(action == "result" && c.Role == "reader")) {
		return false
	}
	parts := strings.Split(c.OriginalKey, "/")
	if len(parts) < 2 {
		return false
	}
	id, err := uuid.Parse(parts[1])
	if err != nil || id == uuid.Nil || id.String() != parts[1] {
		return false
	}
	if parts[0] == "proof" {
		return len(parts) == 3 && cashStatementDigest.MatchString(parts[2])
	}
	return len(parts) == 2 && (parts[0] == "refund" || parts[0] == "alternative" || parts[0] == "dispute")
}

type cashOriginalRetryReceipt struct {
	Format              int                       `json:"format"`
	State               string                    `json:"state"`
	Operation           uuid.UUID                 `json:"operation"`
	OriginalKey         string                    `json:"originalKey"`
	BasisDigest         *string                   `json:"basisDigest"`
	Scope               *CashArchiveOriginalScope `json:"scope"`
	Scheduled           *int64                    `json:"scheduled"`
	Busy                *bool                     `json:"busy"`
	FinancialAuthority  *bool                     `json:"financialAuthority"`
	ExecutionAuthorized *bool                     `json:"executionAuthorized"`
}

/** SQL 原回执必须匹配完整路由；未知回执没有虚构的已调度数量，也没有财务执行许可。 */
func (v cashOriginalRetryReceipt) valid(q CashOriginalRetryCommand, route CashArchiveOriginalScope) bool {
	if v.Format != 1 || v.Operation != q.Operation || v.OriginalKey != q.OriginalKey ||
		v.FinancialAuthority == nil || *v.FinancialAuthority || v.ExecutionAuthorized == nil || *v.ExecutionAuthorized {
		return false
	}
	if v.State == "operation_unknown" {
		return v.BasisDigest == nil && v.Scope == nil && v.Scheduled == nil && v.Busy == nil
	}
	if v.BasisDigest == nil || *v.BasisDigest != q.BasisDigest || v.Scope == nil || *v.Scope != route ||
		v.Scheduled == nil || *v.Scheduled < 0 || v.Busy == nil {
		return false
	}
	switch v.State {
	case "queued":
		return *v.Scheduled > 0
	case "original_busy":
		return *v.Scheduled == 0 && *v.Busy
	case "original_not_scheduled", "original_unavailable", "basis_changed", "review_required":
		return *v.Scheduled == 0 && !*v.Busy
	default:
		return false
	}
}

/** 重试最多发一次原 SQL 命令；响应、提交或权限未知只返回未知，客户端须查询同一操作。 */
func (s *MetonCashArchive) RetryOriginal(ctx context.Context, source MetonManagedSource, q CashOriginalRetryRequest, action string) (json.RawMessage, error) {
	live, ok := MetonSource()
	key, enabled := source.CashOriginalRetryKeyID()
	if s == nil || !ok || live != source || !enabled || !source.ValidCashOriginalRetry(q, action) ||
		q.ScopeKey != s.identity.ScopeKey || q.Environment != s.identity.Environment || q.Source != s.identity.Source || q.Epoch != s.identity.Epoch {
		return nil, ErrMetonClosed
	}
	store, available := s.store.(CashOriginalRetryStore)
	if !available {
		return nil, ErrMetonClosed
	}
	select {
	case s.budget <- struct{}{}:
		defer func() { <-s.budget }()
	default:
		return nil, ErrMetonClosed
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	raw, err := store.RetryCashOriginal(ctx, q.Command, action)
	if err != nil || len(raw) == 0 || len(raw) > 8192 {
		return nil, ErrMetonClosed
	}
	var receipt cashOriginalRetryReceipt
	if decodeStatement(raw, &receipt) != nil || receipt.Scope != nil && (receipt.Scope.Deployment != s.identity.Environment ||
		receipt.Scope.Source != s.identity.Source || receipt.Scope.Epoch != s.identity.Epoch || receipt.Scope.KeyRef != s.identity.KeyRef ||
		receipt.Scope.InboxSystem != s.identity.ArchiveSystem) {
		return nil, ErrMetonClosed
	}
	// 实际路由的全字段比较在仓储先完成；出站再封闭公开字段，不输出商户路由或人员材料。
	if receipt.Scope == nil {
		if !receipt.valid(q.Command, CashArchiveOriginalScope{}) {
			return nil, ErrMetonClosed
		}
	} else if !receipt.valid(q.Command, *receipt.Scope) {
		return nil, ErrMetonClosed
	}
	live, ok = MetonSource()
	current, enabled := source.CashOriginalRetryKeyID()
	if !ok || live != source || !enabled || current != key || ctx.Err() != nil || !q.Command.Until.After(time.Now()) {
		return nil, ErrMetonClosed
	}
	return json.Marshal(struct {
		Format              int       `json:"format"`
		State               string    `json:"state"`
		Environment         string    `json:"environment"`
		Source              string    `json:"source"`
		Epoch               int64     `json:"epoch"`
		ScopeKey            string    `json:"scopeKey"`
		KeyRef              uuid.UUID `json:"keyRef"`
		ArchiveSystem       string    `json:"archiveSystem"`
		Operation           uuid.UUID `json:"operation"`
		OriginalKey         string    `json:"originalKey"`
		BasisDigest         string    `json:"basisDigest"`
		Scheduled           *int64    `json:"scheduled"`
		Busy                *bool     `json:"busy"`
		FinancialAuthority  bool      `json:"financialAuthority"`
		ExecutionAuthorized bool      `json:"executionAuthorized"`
	}{1, receipt.State, q.Environment, q.Source, q.Epoch, q.ScopeKey, s.identity.KeyRef, s.identity.ArchiveSystem,
		q.Command.Operation, q.Command.OriginalKey, q.Command.BasisDigest, receipt.Scheduled, receipt.Busy, false, false})
}
