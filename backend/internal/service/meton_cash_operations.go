package service

import (
	"context"
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
)

/** 运营查询另用来源身份，不能借普通账单、用户登录或退款执行身份扩大读取范围。 */
type CashOperationsRequest struct {
	OriginalKey  *string             `json:"originalKey,omitempty"`
	Scope        MetonStatementScope `json:"scope"`
	SourceSystem string              `json:"sourceSystem"`
	After        *string             `json:"after"`
	Size         int                 `json:"size"`
}
type MetonCashOperationsStore interface {
	ReadCashOperations(context.Context, MetonManagedSource, CashOperationsRequest) (json.RawMessage, error)
}
type MetonCashOperations struct {
	store  MetonCashOperationsStore
	budget chan struct{}
}

/** 新用途显式检查全部已登记身份，换一份相同身份的秘密也不能与原资金权限混用。 */
func (s MetonManagedSource) CashOperationsKeyID() (string, bool) {
	return independentCashReadKey("METON_MANAGED_CASH_OPERATIONS_READ_KEY_ID")
}

/** 资金读取身份不能在两个用途间共用；各调用者仍须分别检查自己的固定路由。 */
func independentCashReadKey(name string) (string, bool) {
	id := os.Getenv(name)
	if !MetonManagedBuild || os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || !metonKeyID.MatchString(id) {
		return "", false
	}
	for _, entry := range os.Environ() {
		key, value, _ := strings.Cut(entry, "=")
		if key != name && strings.HasPrefix(key, "METON_MANAGED_") && strings.HasSuffix(key, "_KEY_ID") && value == id {
			return "", false
		}
	}
	return id, true
}

func ReadCashOperationsRequest(raw []byte, q *CashOperationsRequest) error {
	return decodeStatement(raw, q)
}

var cashOperationsCursor = regexp.MustCompile(`^[a-z_]+/[A-Za-z0-9_./:-]{1,200}$`)

func (s MetonManagedSource) ValidCashOperations(q CashOperationsRequest) bool {
	return s.ValidClaim(&q.Scope.MetonManagedClaim) && q.Scope.RemoteUser > 0 && q.Scope.SourceMarker != uuid.Nil &&
		closureSystem.MatchString(q.SourceSystem) && q.Size >= 1 && q.Size <= 100 &&
		(q.After == nil || cashOperationsCursor.MatchString(*q.After)) &&
		(q.OriginalKey == nil || q.After == nil && q.Size == 1 && cashOperationsCursor.MatchString(*q.OriginalKey))
}
func (q CashOperationsRequest) Origin() CashStatementOrigin {
	c := q.Scope
	return CashStatementOrigin{c.Environment, c.Source, c.Epoch, c.User, c.Account, c.Operation, c.Dispatch, c.RemoteUser, c.SourceMarker, q.SourceSystem}
}

/** 只接只读端口；独立名额没有无界等待，也不借用模型或收款通知的连接预算。 */
func NewMetonCashOperations(store MetonCashOperationsStore) *MetonCashOperations {
	if store == nil {
		return nil
	}
	return &MetonCashOperations{store: store, budget: make(chan struct{}, 8)}
}

func (s *MetonCashOperations) Read(ctx context.Context, source MetonManagedSource, q CashOperationsRequest) (json.RawMessage, error) {
	live, ok := MetonSource()
	key, enabled := source.CashOperationsKeyID()
	if s == nil || s.store == nil || !ok || live != source || !enabled || !source.ValidCashOperations(q) {
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
	raw, err := s.store.ReadCashOperations(ctx, source, q)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw) > 196608 {
		return nil, ErrMetonClosed
	}
	var value cashOperationsEnvelope
	if decodeStatement(raw, &value) != nil || !value.matches(q) {
		return nil, ErrMetonClosed
	}
	live, ok = MetonSource()
	current, enabled := source.CashOperationsKeyID()
	if !ok || live != source || !enabled || current != key || ctx.Err() != nil {
		return nil, ErrMetonClosed
	}
	return raw, nil
}

type cashOperationsEnvelope struct {
	Format              int                  `json:"format"`
	State               string               `json:"state"`
	Origin              CashStatementOrigin  `json:"origin"`
	ObservedAt          time.Time            `json:"observedAt"`
	Scope               string               `json:"scope"`
	After               *string              `json:"after"`
	Size                int                  `json:"size"`
	Next                *string              `json:"next"`
	More                bool                 `json:"more"`
	Items               []cashOperationsItem `json:"items"`
	FinancialAuthority  *bool                `json:"financialAuthority"`
	ExecutionAuthorized *bool                `json:"executionAuthorized"`
}
type cashOperationsItem struct {
	Key         string     `json:"key"`
	OpenedAt    *time.Time `json:"openedAt"`
	BasisDigest string     `json:"basisDigest"`
	Original    struct {
		Kind  string                     `json:"kind"`
		Ref   string                     `json:"ref"`
		Value map[string]json.RawMessage `json:"value"`
	} `json:"original"`
}

func sameOperationsCursor(a, b *string) bool {
	return a == nil && b == nil || a != nil && b != nil && *a == *b
}

/** 每页归属和原事项摘要都核对；分页结束或事项不可见不代表资金已经结清。 */
func (v cashOperationsEnvelope) matches(q CashOperationsRequest) bool {
	if v.Format != 1 || v.State != "observed" || v.Scope != "current_original_page" || v.Origin != q.Origin() ||
		v.ObservedAt.Before(time.Unix(0, 0)) || v.ObservedAt.After(time.Now().Add(time.Minute)) || !sameOperationsCursor(v.After, q.After) ||
		v.Size != q.Size || v.Items == nil || len(v.Items) > q.Size || v.More && len(v.Items) != q.Size ||
		v.FinancialAuthority == nil || *v.FinancialAuthority || v.ExecutionAuthorized == nil || *v.ExecutionAuthorized {
		return false
	}
	if q.OriginalKey != nil {
		if v.More {
			return false
		}
		for _, item := range v.Items {
			if item.Key != *q.OriginalKey {
				return false
			}
		}
	}
	previous := q.After
	for _, item := range v.Items {
		if !cashOperationsCursor.MatchString(item.Key) || item.Key != item.Original.Kind+"/"+item.Original.Ref ||
			previous != nil && item.Key <= *previous || !cashStatementDigest.MatchString(item.BasisDigest) ||
			item.OpenedAt != nil && (item.OpenedAt.Before(time.Unix(0, 0)) || item.OpenedAt.After(v.ObservedAt)) {
			return false
		}
		switch item.Original.Kind {
		case "order", "payment", "cash_basis", "legacy_order", "legacy_basis", "legacy_activity", "legacy_refund_audit", "unmapped_order", "refund", "cash_review", "dispute":
		default:
			return false
		}
		var category string
		if json.Unmarshal(item.Original.Value["category"], &category) != nil || category == "" {
			return false
		}
		key := item.Key
		previous = &key
	}
	return sameOperationsCursor(v.Next, previous)
}
