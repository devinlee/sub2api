package service

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"os"
	"time"
)

/** MetonStatementScope 固定原创建和来源标识；查询不能用当前余额推导另一个账户。 */
type MetonStatementScope struct {
	MetonManagedClaim
	RemoteUser   int64     `json:"remoteUser"`
	SourceMarker uuid.UUID `json:"sourceMarker"`
}
type MetonStatementCursor struct {
	Sequence int64      `json:"sequence"`
	Event    *uuid.UUID `json:"event"`
	After    int64      `json:"after"`
	Size     int        `json:"size"`
}
type MetonStatementRequest struct {
	Scope   MetonStatementScope   `json:"scope"`
	From    string                `json:"from"`
	Through string                `json:"through"`
	Page    *MetonStatementCursor `json:"page"`
}
type MetonStatementStore interface {
	Statement(context.Context, MetonManagedSource, MetonStatementRequest) (json.RawMessage, error)
}
type MetonStatements struct {
	store MetonStatementStore
	cash  MetonCashStatementStore
}

/** StatementKeyID 查询身份不能兼任任何已登记的资金、会话或原创建权限。 */
func (s MetonManagedSource) StatementKeyID() (string, bool) {
	id := os.Getenv("METON_MANAGED_STATEMENT_READ_KEY_ID")
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || !metonKeyID.MatchString(id) {
		return "", false
	}
	for _, purpose := range []string{"CREATE", "READ", "FUNDS_READ", "ISSUE", "INSPECT", "ROTATE", "CLOSE", "GRANT_WRITE", "GRANT_READ", "MODEL_READ", "MODEL_CANCEL", "GIFT_READ", "GIFT_CLOSE"} {
		if os.Getenv("METON_MANAGED_"+purpose+"_KEY_ID") == id {
			return "", false
		}
	}
	return id, true
}

/** ReadMetonStatementRequest 严格解析也受构建边界控制，普通版本不能启用托管查询。 */
func ReadMetonStatementRequest(raw []byte, q *MetonStatementRequest) error {
	return decodeStatement(raw, q)
}
func (s MetonManagedSource) ValidStatement(q MetonStatementRequest) bool {
	if !s.ValidClaim(&q.Scope.MetonManagedClaim) || q.Scope.RemoteUser <= 0 || q.Scope.SourceMarker == uuid.Nil {
		return false
	}
	from, e1 := time.Parse("2006-01-02", q.From)
	through, e2 := time.Parse("2006-01-02", q.Through)
	if e1 != nil || e2 != nil || from.Before(time.Unix(0, 0)) || through.Before(from) || through.Sub(from) > 30*24*time.Hour || through.After(time.Now().UTC()) {
		return false
	}
	p := q.Page
	return p == nil || p.Sequence >= 0 && p.After >= 0 && p.After <= p.Sequence && p.Size >= 1 && p.Size <= 100 &&
		(p.Sequence == 0 && p.Event == nil || p.Sequence > 0 && p.Event != nil && *p.Event != uuid.Nil)
}

/** NewMetonStatements 只接只读仓储，不给查询对象保留来源写入端口。 */
func NewMetonStatements(store MetonStatementStore) *MetonStatements {
	if store == nil {
		return nil
	}
	return &MetonStatements{store: store}
}

/** Read 前后复验来源和受限身份；来源切换或回执错归属时不交出旧账单。 */
func (s *MetonStatements) Read(ctx context.Context, source MetonManagedSource, q MetonStatementRequest) (json.RawMessage, error) {
	live, ok := MetonSource()
	id, enabled := source.StatementKeyID()
	if s == nil || s.store == nil || !ok || live != source || !enabled || !source.ValidStatement(q) {
		return nil, ErrMetonClosed
	}
	raw, err := s.store.Statement(ctx, source, q)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw) > 196608 {
		return nil, ErrMetonClosed
	}
	var v statementEnvelope
	if decodeStatement(raw, &v) != nil || !v.matches(q) {
		return nil, ErrMetonClosed
	}
	now, ok := MetonSource()
	key, enabled := source.StatementKeyID()
	if !ok || now != source || !enabled || key != id || ctx.Err() != nil {
		return nil, ErrMetonClosed
	}
	return raw, nil
}

type statementEnvelope struct {
	Version int `json:"version"`
	Origin  struct {
		Environment  string    `json:"environment"`
		Source       string    `json:"source"`
		Epoch        int64     `json:"epoch"`
		User         uuid.UUID `json:"user"`
		Account      uuid.UUID `json:"account"`
		Creation     uuid.UUID `json:"creation"`
		Dispatch     uuid.UUID `json:"dispatch"`
		RemoteUser   int64     `json:"remote_user"`
		SourceMarker uuid.UUID `json:"source_marker"`
	} `json:"origin"`
	Cut struct {
		Sequence   int64      `json:"sequence"`
		Event      *uuid.UUID `json:"event"`
		ObservedAt *time.Time `json:"observed_at"`
	} `json:"cut"`
	Period struct {
		From    string  `json:"from"`
		Through string  `json:"through"`
		Unit    *string `json:"unit"`
		Opening *string `json:"opening"`
		Net     *string `json:"net"`
		Closing *string `json:"closing"`
		Events  *int64  `json:"events"`
	} `json:"period"`
	State  string          `json:"state"`
	Funds  json.RawMessage `json:"funds"`
	Limits json.RawMessage `json:"limits"`
	After  *int64          `json:"after"`
	Size   *int            `json:"size"`
	Last   *int64          `json:"last"`
	Count  *int            `json:"count"`
	More   *bool           `json:"more"`
	Items  json.RawMessage `json:"items"`
}

func (v statementEnvelope) matches(q MetonStatementRequest) bool {
	o, c := v.Origin, q.Scope
	if v.Version != 1 || o.Environment != c.Environment || o.Source != c.Source || o.Epoch != c.Epoch || o.User != c.User || o.Account != c.Account ||
		o.Creation != c.Operation || o.Dispatch != c.Dispatch || o.RemoteUser != c.RemoteUser || o.SourceMarker != c.SourceMarker || v.Period.From != q.From || v.Period.Through != q.Through ||
		v.Cut.Sequence < 0 || v.Cut.Sequence == 0 && v.Cut.Event != nil || v.Cut.Sequence > 0 && (v.Cut.Event == nil || *v.Cut.Event == uuid.Nil) {
		return false
	}
	if q.Page == nil {
		return (v.State == "empty" && v.Cut.Sequence == 0 || v.State == "observed" && v.Cut.Sequence > 0) && v.Cut.ObservedAt != nil &&
			!v.Cut.ObservedAt.Before(time.Unix(0, 0)) && !v.Cut.ObservedAt.After(time.Now().Add(time.Minute)) && v.Period.Opening != nil && v.Period.Net != nil && v.Period.Closing != nil &&
			v.Period.Events != nil && *v.Period.Events >= 0 && len(v.Funds) > 2 && len(v.Limits) > 2 && v.After == nil && v.Items == nil
	}
	p := q.Page
	sameTip := p.Event == nil && v.Cut.Event == nil || p.Event != nil && v.Cut.Event != nil && *p.Event == *v.Cut.Event
	return v.Cut.Sequence == p.Sequence && sameTip && v.Cut.ObservedAt == nil && v.State == "" && v.Funds == nil && v.Limits == nil && v.Period.Events == nil &&
		v.After != nil && *v.After == p.After && v.Size != nil && *v.Size == p.Size && v.Last != nil && *v.Last >= p.After && *v.Last <= p.Sequence &&
		v.Count != nil && *v.Count >= 0 && *v.Count <= p.Size && v.More != nil && len(v.Items) > 0
}
