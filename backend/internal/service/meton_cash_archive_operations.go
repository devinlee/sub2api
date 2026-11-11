package service

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"strings"
	"time"
)

/** 商户归档查询不接受账号字段；ScopeKey 来自部署方固定的归档范围。 */
type CashArchiveRequest struct {
	OriginalKey *string `json:"originalKey,omitempty"`
	Version     int     `json:"version"`
	Environment string  `json:"environment"`
	Source      string  `json:"source"`
	Epoch       int64   `json:"epoch"`
	ScopeKey    string  `json:"scopeKey"`
	After       *string `json:"after"`
	Size        int     `json:"size"`
}

/** 受信部署绑定，不携带现金秘密或任何派发许可。 */
type CashArchiveIdentity struct {
	Environment   string    `json:"environment"`
	Source        string    `json:"source"`
	Epoch         int64     `json:"epoch"`
	ScopeKey      string    `json:"scopeKey"`
	KeyRef        uuid.UUID `json:"keyRef"`
	ArchiveSystem string    `json:"archiveSystem"`
}
type CashArchiveStore interface {
	ReadCashArchive(context.Context, CashArchiveRequest) (json.RawMessage, error)
}
type MetonCashArchive struct {
	store    CashArchiveStore
	identity CashArchiveIdentity
	budget   chan struct{}
}

/** 归档入口与本人原账入口使用不同的受限原生身份。 */
func (s MetonManagedSource) CashArchiveKeyID() (string, bool) {
	return independentCashReadKey("METON_MANAGED_CASH_ARCHIVE_READ_KEY_ID")
}

/** 普通构建沿既有拒绝解码器关闭，不因环境变量启用归档权限。 */
func ReadCashArchiveRequest(raw []byte, q *CashArchiveRequest) error { return decodeStatement(raw, q) }

/** 页范围和当前环境必须全部相符；调用者不能临时换商户、账号或归档库。 */
func (s MetonManagedSource) ValidCashArchive(q CashArchiveRequest) bool {
	return q.Version == 1 && q.Environment == s.Environment && q.Source == s.Source && q.Epoch == s.Epoch &&
		cashStatementDigest.MatchString(q.ScopeKey) && q.Size >= 1 && q.Size <= 100 && (q.After == nil || cashOperationsCursor.MatchString(*q.After)) &&
		(q.OriginalKey == nil || q.After == nil && q.Size == 1 && cashOperationsCursor.MatchString(*q.OriginalKey))
}

/** 身份仅由独立读取配置装配，错误配置在监听前失败。 */
func NewMetonCashArchive(store CashArchiveStore, id CashArchiveIdentity) *MetonCashArchive {
	s, ok := MetonSource()
	if store == nil || !ok || id.Environment != s.Environment || id.Source != s.Source || id.Epoch != s.Epoch || id.KeyRef == uuid.Nil ||
		!cashStatementDigest.MatchString(id.ScopeKey) || !closureSystem.MatchString(id.ArchiveSystem) {
		return nil
	}
	return &MetonCashArchive{store: store, identity: id, budget: make(chan struct{}, 8)}
}

/** 独立名额、固定超时和查询前后复验；不重试领取、解密、付款或任何资金操作。 */
func (s *MetonCashArchive) Read(ctx context.Context, source MetonManagedSource, q CashArchiveRequest) (json.RawMessage, error) {
	live, ok := MetonSource()
	key, enabled := source.CashArchiveKeyID()
	if s == nil || s.store == nil || !ok || live != source || !enabled || !source.ValidCashArchive(q) || q.ScopeKey != s.identity.ScopeKey ||
		q.Environment != s.identity.Environment || q.Source != s.identity.Source || q.Epoch != s.identity.Epoch {
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
	raw, err := s.store.ReadCashArchive(ctx, q)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw) > 196608 {
		return nil, ErrMetonClosed
	}
	var page cashArchivePage
	if decodeStatement(raw, &page) != nil || !page.matches(s.identity, q) {
		return nil, ErrMetonClosed
	}
	live, ok = MetonSource()
	current, enabled := source.CashArchiveKeyID()
	if !ok || live != source || !enabled || key != current || ctx.Err() != nil {
		return nil, ErrMetonClosed
	}
	return raw, nil
}

type cashArchivePage struct {
	Format              int               `json:"format"`
	State               string            `json:"state"`
	Scope               string            `json:"scope"`
	ScopeKey            string            `json:"scopeKey"`
	Environment         string            `json:"environment"`
	Source              string            `json:"source"`
	Epoch               int64             `json:"epoch"`
	KeyRef              uuid.UUID         `json:"keyRef"`
	ArchiveSystem       string            `json:"archiveSystem"`
	ObservedAt          time.Time         `json:"observedAt"`
	After               *string           `json:"after"`
	Size                int               `json:"size"`
	Next                *string           `json:"next"`
	More                bool              `json:"more"`
	Items               []cashArchiveItem `json:"items"`
	FinancialAuthority  *bool             `json:"financialAuthority"`
	ExecutionAuthorized *bool             `json:"executionAuthorized"`
}
type cashArchiveItem struct {
	Key         string                     `json:"key"`
	OpenedAt    *time.Time                 `json:"openedAt"`
	BasisDigest string                     `json:"basisDigest"`
	Value       map[string]json.RawMessage `json:"value"`
}

var cashArchiveFields = map[string][]string{
	"proof":       {"kind", "receipt", "proof", "noticeKind", "ownership", "firstSeen", "firstProof", "conflicted", "unindexedRefund", "scopeApps", "deliveries"},
	"refund":      {"kind", "refund", "ownership", "initialMode", "gateChoice", "state", "revision", "hasLease", "nextCheckAt", "cashObserved", "cashConflict"},
	"alternative": {"kind", "refund", "ownership", "choice", "state", "hasLease", "nextCheckAt", "cashObserved"},
	"dispute":     {"kind", "dispute", "ownership", "state", "revision", "updatedAt", "assigned", "assignmentEpoch", "evidenceEpoch", "requiresCurrentReview"},
}

/** SQL 公开字段也在出站处封闭；原密文、人员材料或未知嵌套字段不能透传。 */
func (v cashArchiveItem) valid() bool {
	kind, _, ok := strings.Cut(v.Key, "/")
	fields, known := cashArchiveFields[kind]
	if !ok || !known || len(v.Value) != len(fields) {
		return false
	}
	for _, name := range fields {
		raw, exists := v.Value[name]
		if !exists {
			return false
		}
		if name == "deliveries" {
			var states map[string]int64
			if json.Unmarshal(raw, &states) != nil || states == nil {
				return false
			}
			for state, count := range states {
				if count < 0 {
					return false
				}
				switch state {
				case "claimed", "retry", "posted", "review", "foreign":
				default:
					return false
				}
			}
		} else {
			var value any
			if json.Unmarshal(raw, &value) != nil {
				return false
			}
			switch x := value.(type) {
			case map[string]any, []any:
				return false
			case string:
				if len(x) > 256 {
					return false
				}
			}
		}
	}
	var actual, ref, digest, ownership string
	if json.Unmarshal(v.Value["kind"], &actual) != nil || actual != kind || json.Unmarshal(v.Value["ownership"], &ownership) != nil {
		return false
	}
	field := "refund"
	if kind == "proof" {
		field = "receipt"
	} else if kind == "dispute" {
		field = "dispute"
	}
	if json.Unmarshal(v.Value[field], &ref) != nil {
		return false
	}
	id, err := uuid.Parse(ref)
	if err != nil || id == uuid.Nil || id.String() != ref {
		return false
	}
	expected := kind + "/" + ref
	if kind == "proof" {
		if ownership != "not_resolved_by_listing" || json.Unmarshal(v.Value["proof"], &digest) != nil || !cashStatementDigest.MatchString(digest) {
			return false
		}
		expected += "/" + digest
	} else if ownership != "original_binding" {
		return false
	}
	return v.Key == expected
}

/** 每页的代次、范围和原项都复验；结束页不是结清证明。 */
func (p cashArchivePage) matches(id CashArchiveIdentity, q CashArchiveRequest) bool {
	if p.Format != 1 || p.State != "observed" || p.Scope != "merchant_archive_all_apps" || p.ScopeKey != id.ScopeKey || p.Environment != id.Environment ||
		p.Source != id.Source || p.Epoch != id.Epoch || p.KeyRef != id.KeyRef || p.ArchiveSystem != id.ArchiveSystem ||
		!sameOperationsCursor(p.After, q.After) || p.Size != q.Size || p.Items == nil || len(p.Items) > q.Size || p.More && len(p.Items) != q.Size ||
		p.ObservedAt.Before(time.Unix(0, 0)) || p.ObservedAt.After(time.Now().Add(time.Minute)) ||
		p.FinancialAuthority == nil || *p.FinancialAuthority || p.ExecutionAuthorized == nil || *p.ExecutionAuthorized {
		return false
	}
	if q.OriginalKey != nil {
		if p.More {
			return false
		}
		for _, item := range p.Items {
			if item.Key != *q.OriginalKey {
				return false
			}
		}
	}
	previous := q.After
	for _, item := range p.Items {
		if !cashOperationsCursor.MatchString(item.Key) || previous != nil && item.Key <= *previous || !cashStatementDigest.MatchString(item.BasisDigest) || !item.valid() ||
			item.OpenedAt != nil && (item.OpenedAt.Before(time.Unix(0, 0)) || item.OpenedAt.After(p.ObservedAt)) {
			return false
		}
		key := item.Key
		previous = &key
	}
	return sameOperationsCursor(p.Next, previous)
}
