package service

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

/** 关联端口只有精确只读操作；归档签章和账号绑定不交给外部调用者。 */
type CashArchiveOriginalStore interface {
	ReadCashArchiveOriginal(context.Context, CashArchiveRequest) (json.RawMessage, error)
}

/** 两个实际数据库和商户路由只由部署配置提供，HTTP 请求不能改写。 */
type CashArchiveOriginalScope struct {
	Deployment      string    `json:"deployment"`
	Source          string    `json:"source"`
	Epoch           int64     `json:"epoch"`
	KeyRef          uuid.UUID `json:"keyRef"`
	SourceSystem    string    `json:"sourceSystem"`
	InboxSystem     string    `json:"inboxSystem"`
	Channel         string    `json:"channel"`
	CashEnvironment string    `json:"cashEnvironment"`
	Merchant        string    `json:"merchant"`
}

type cashArchiveOriginalObservation struct {
	Format              int                      `json:"format"`
	State               string                   `json:"state"`
	Scope               CashArchiveOriginalScope `json:"scope"`
	ScopeKey            string                   `json:"scopeKey"`
	OriginalKey         string                   `json:"originalKey"`
	ArchiveBasisDigest  *string                  `json:"archiveBasisDigest"`
	Original            *cashOperationsItem      `json:"original"`
	ObservedAt          time.Time                `json:"observedAt"`
	FinancialAuthority  *bool                    `json:"financialAuthority"`
	ExecutionAuthorized *bool                    `json:"executionAuthorized"`
	BasisDigest         string                   `json:"basisDigest"`
	CashMatch           *string                  `json:"cashMatch"`
}

/** 精确原号、当前身份、范围和公开字段同时核对；未知原事项不会被改写为终态。 */
func (v cashArchiveOriginalObservation) matches(id CashArchiveIdentity, q CashArchiveRequest) bool {
	if q.OriginalKey == nil || v.Format != 1 || v.OriginalKey != *q.OriginalKey || v.ScopeKey != id.ScopeKey ||
		v.Scope.Deployment != id.Environment || v.Scope.Source != id.Source || v.Scope.Epoch != id.Epoch || v.Scope.KeyRef != id.KeyRef ||
		v.Scope.InboxSystem != id.ArchiveSystem || !closureSystem.MatchString(v.Scope.SourceSystem) || v.Scope.SourceSystem == v.Scope.InboxSystem ||
		v.Scope.Channel != "wechatpay" || v.Scope.CashEnvironment != "isolated" && v.Scope.CashEnvironment != "live" ||
		len(v.Scope.Merchant) == 0 || len(v.Scope.Merchant) > 32 || !cashStatementDigest.MatchString(v.BasisDigest) ||
		v.FinancialAuthority == nil || *v.FinancialAuthority || v.ExecutionAuthorized == nil || *v.ExecutionAuthorized ||
		v.ObservedAt.Before(time.Now().Add(-30*time.Second)) || v.ObservedAt.After(time.Now().Add(time.Minute)) ||
		v.ArchiveBasisDigest != nil && !cashStatementDigest.MatchString(*v.ArchiveBasisDigest) {
		return false
	}
	if v.CashMatch != nil && (*v.CashMatch != "matched" || v.State != "observed" || !strings.HasPrefix(v.OriginalKey, "alternative/")) {
		return false
	}
	if v.State == "original_unavailable" || v.State == "original_unlinked" {
		return v.Original == nil && (v.State != "original_unlinked" || v.ArchiveBasisDigest != nil)
	}
	x := v.Original
	if v.State != "observed" || x == nil || v.ArchiveBasisDigest == nil || !cashStatementDigest.MatchString(x.BasisDigest) ||
		x.Key != x.Original.Kind+"/"+x.Original.Ref || x.OpenedAt != nil && (x.OpenedAt.Before(time.Unix(0, 0)) || x.OpenedAt.After(v.ObservedAt)) {
		return false
	}
	kind, ref, ok := strings.Cut(v.OriginalKey, "/")
	if !ok {
		return false
	}
	if kind == "proof" {
		if x.Original.Kind != "payment" && x.Original.Kind != "refund" {
			return false
		}
	} else if ref != x.Original.Ref || (kind != x.Original.Kind && !(kind == "alternative" && x.Original.Kind == "refund")) {
		return false
	}
	if id, err := uuid.Parse(x.Original.Ref); err != nil || id == uuid.Nil {
		return false
	}
	fields := map[string]bool{}
	switch x.Original.Kind {
	case "payment":
		for _, name := range []string{"category", "order", "state", "version", "currency", "payerFen", "orderFen"} {
			fields[name] = true
		}
	case "refund":
		// 原确认编号由来源迁移 359 按原账号选择；归档关联读取与本人账单使用同一公开字段。
		for _, name := range []string{"category", "intent", "order", "part", "cutoff", "basis", "phase", "version", "fen", "units", "cashConfirmed", "sourceSettled", "recoveryConfirmed"} {
			fields[name] = true
		}
	case "dispute":
		for _, name := range []string{"category", "order", "revision", "status"} {
			fields[name] = true
		}
	default:
		return false
	}
	var category string
	if json.Unmarshal(x.Original.Value["category"], &category) != nil || category == "" {
		return false
	}
	for name, raw := range x.Original.Value {
		if !fields[name] {
			return false
		}
		if name == "status" {
			var child map[string]json.RawMessage
			if json.Unmarshal(raw, &child) != nil || child == nil {
				return false
			}
			for key, value := range child {
				if key != "state" && key != "revision" && key != "phase" && key != "outcome" || !archiveOriginalScalar(value) {
					return false
				}
			}
		} else if !archiveOriginalScalar(raw) {
			return false
		}
	}
	return true
}

/** 普通观察只允许有限标量，不输出密文、签名或嵌套内部材料。 */
func archiveOriginalScalar(raw json.RawMessage) bool {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return false
	}
	switch x := value.(type) {
	case map[string]any, []any:
		return false
	case string:
		return len(x) <= 1024
	default:
		return true
	}
}

/** 共用归档入口的有界名额，读后复验当前原生身份；没有重发或资金写分支。 */
func (s *MetonCashArchive) ReadOriginal(ctx context.Context, source MetonManagedSource, q CashArchiveRequest) (json.RawMessage, error) {
	live, ok := MetonSource()
	key, enabled := source.CashArchiveKeyID()
	if s == nil || s.store == nil || !ok || live != source || !enabled || !source.ValidCashArchive(q) || q.OriginalKey == nil ||
		q.ScopeKey != s.identity.ScopeKey || q.Environment != s.identity.Environment || q.Source != s.identity.Source || q.Epoch != s.identity.Epoch {
		return nil, ErrMetonClosed
	}
	store, supported := s.store.(CashArchiveOriginalStore)
	if !supported {
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
	raw, err := store.ReadCashArchiveOriginal(ctx, q)
	if err != nil {
		return nil, err
	}
	var value cashArchiveOriginalObservation
	if len(raw) == 0 || len(raw) > 65536 || decodeStatement(raw, &value) != nil || !value.matches(s.identity, q) {
		return nil, ErrMetonClosed
	}
	live, ok = MetonSource()
	current, enabled := source.CashArchiveKeyID()
	if !ok || live != source || !enabled || current != key || ctx.Err() != nil {
		return nil, ErrMetonClosed
	}
	return raw, nil
}
