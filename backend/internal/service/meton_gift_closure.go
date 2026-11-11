package service

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"os"
	"time"
)

/** MetonGiftScope 始终指向同一次注册的原来源，不接受用户提交的余额或替代账号。 */
type MetonGiftScope struct {
	MetonManagedClaim
	RemoteUser   int64     `json:"remoteUser"`
	SourceMarker uuid.UUID `json:"sourceMarker"`
	Eligibility  uuid.UUID `json:"eligibility"`
}
type MetonGiftFinal struct {
	Decision        uuid.UUID `json:"decision"`
	Registration    uuid.UUID `json:"registration"`
	IdentityEvent   uuid.UUID `json:"identityEvent"`
	SecurityVersion int64     `json:"securityVersion"`
	IdentityEpoch   int64     `json:"identityEpoch"`
}
type MetonGiftRequest struct {
	Scope MetonGiftScope  `json:"scope"`
	Final *MetonGiftFinal `json:"final"`
}

/** ReadMetonGiftRequest 仅解析本协议，实际构建决定是否具备该能力。 */
func ReadMetonGiftRequest(raw []byte, out *MetonGiftRequest) error { return decodeGift(raw, out) }

type MetonGiftFunds struct {
	State           string `json:"state"`
	Balance         string `json:"balance"`
	SourceRemaining string `json:"sourceRemaining"`
	Held            string `json:"held"`
	RefundHeld      string `json:"refundHeld"`
	Pending         int64  `json:"pending"`
}
type MetonGiftReceipt struct {
	Scope   MetonGiftScope  `json:"scope"`
	Funds   MetonGiftFunds  `json:"funds"`
	Final   *MetonGiftFinal `json:"final"`
	Retired string          `json:"retired"`
	Effects int64           `json:"effects"`
	Cutoff  int64           `json:"cutoff"`
}
type MetonGiftClosureStore interface {
	GiftClosure(context.Context, MetonManagedSource, string, MetonGiftRequest) (json.RawMessage, error)
}
type MetonGiftClosure struct{ store MetonGiftClosureStore }

var ErrMetonGiftConflict = errors.New("original gift closure requires reconciliation")

/** NewMetonGiftClosure 只接受启动时装配的受限仓储，没有原生余额修改后备。 */
func NewMetonGiftClosure(store MetonGiftClosureStore) *MetonGiftClosure {
	if store == nil {
		return nil
	}
	return &MetonGiftClosure{store}
}
func (s MetonManagedSource) GiftClosureKeyID(write bool) (string, bool) {
	w, r := os.Getenv("METON_MANAGED_GIFT_CLOSE_KEY_ID"), os.Getenv("METON_MANAGED_GIFT_READ_KEY_ID")
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || !metonKeyID.MatchString(w) || !metonKeyID.MatchString(r) || w == r {
		return "", false
	}
	for _, name := range []string{"CREATE", "READ", "FUNDS_READ", "ISSUE", "INSPECT", "ROTATE", "CLOSE", "GRANT_WRITE", "GRANT_READ", "MODEL_READ", "MODEL_CANCEL"} {
		other := os.Getenv("METON_MANAGED_" + name + "_KEY_ID")
		if other == w || other == r {
			return "", false
		}
	}
	if write {
		return w, true
	}
	return r, true
}
func (f *MetonGiftFinal) Valid() bool {
	return f != nil && f.Decision != uuid.Nil && f.Registration != uuid.Nil && f.IdentityEvent != uuid.Nil && f.SecurityVersion > 0 && f.IdentityEpoch > 0
}
func (s MetonManagedSource) ValidGiftRequest(q MetonGiftRequest, action string) bool {
	c := q.Scope
	return s.ValidClaim(&c.MetonManagedClaim) && c.RemoteUser > 0 && c.SourceMarker != uuid.Nil && c.Eligibility != uuid.Nil &&
		((action == "inspect" && q.Final == nil) || ((action == "terminate" || action == "reconcile") && q.Final.Valid()))
}

/** Execute 每次只执行所选原操作；错误与缺回执保持未知，不自动把查询改为写入。 */
func (s *MetonGiftClosure) Execute(ctx context.Context, source MetonManagedSource, action string, q MetonGiftRequest) (*MetonGiftReceipt, error) {
	live, available := MetonSource()
	_, allowed := source.GiftClosureKeyID(action != "inspect")
	if s == nil || s.store == nil || !available || live != source || !allowed || !source.ValidGiftRequest(q, action) {
		return nil, ErrMetonClosed
	}
	raw, err := s.store.GiftClosure(ctx, source, action, q)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return nil, ErrMetonClosed
	}
	result, err := giftReceipt(raw, q)
	if current, ok := MetonSource(); !ok || current != source {
		return nil, ErrMetonClosed
	}
	return result, err
}

// giftSnapshot 是来源函数的完整窄结果；不向外传全部历史效果列表。
type giftSnapshot struct {
	Environment  string    `json:"environment"`
	Source       string    `json:"source"`
	Epoch        int64     `json:"epoch"`
	User         uuid.UUID `json:"user"`
	Account      uuid.UUID `json:"account"`
	Creation     uuid.UUID `json:"creation"`
	Dispatch     uuid.UUID `json:"dispatch"`
	RemoteUser   int64     `json:"remote_user"`
	SourceMarker uuid.UUID `json:"source_marker"`
	Eligibility  uuid.UUID `json:"eligibility"`
	Funds        struct {
		State      string `json:"state"`
		Balance    string `json:"balance"`
		Gift       string `json:"gift"`
		Held       string `json:"held"`
		RefundHeld string `json:"refund_held"`
		Pending    int64  `json:"pending"`
	} `json:"funds"`
	Termination *struct {
		Decision        uuid.UUID `json:"decision"`
		SourceMarker    uuid.UUID `json:"source_marker"`
		Environment     string    `json:"environment"`
		Source          string    `json:"source"`
		Epoch           int64     `json:"epoch"`
		User            uuid.UUID `json:"meton_user"`
		Account         uuid.UUID `json:"account"`
		Creation        uuid.UUID `json:"creation"`
		Dispatch        uuid.UUID `json:"dispatch"`
		RemoteUser      int64     `json:"remote_user"`
		Eligibility     uuid.UUID `json:"eligibility"`
		Registration    uuid.UUID `json:"registration"`
		IdentityEvent   uuid.UUID `json:"identity_event"`
		SecurityVersion int64     `json:"security_version"`
		IdentityEpoch   int64     `json:"identity_epoch"`
		Cutoff          int64     `json:"cutoff_sequence"`
		RecordedAt      time.Time `json:"recorded_at"`
	} `json:"termination"`
	Retired string `json:"retired"`
	Effects int64  `json:"effect_count"`
}

func giftReceipt(raw []byte, q MetonGiftRequest) (*MetonGiftReceipt, error) {
	var v giftSnapshot
	if decodeGift(raw, &v) != nil {
		return nil, ErrMetonClosed
	}
	scope := MetonGiftScope{MetonManagedClaim{1, v.Environment, v.Source, v.User, v.Account, v.Creation, v.Dispatch, v.Epoch}, v.RemoteUser, v.SourceMarker, v.Eligibility}
	if scope != q.Scope || v.Effects < 0 || v.Funds.Pending < 0 {
		return nil, ErrMetonClosed
	}
	switch v.Funds.State {
	case "empty", "gift_only", "gift_scope_ready", "cash_review", "source_review", "settlement_pending", "scope_unknown":
	default:
		return nil, ErrMetonClosed
	}
	for _, n := range []string{v.Funds.Balance, v.Funds.Gift, v.Funds.Held, v.Funds.RefundHeld, v.Retired} {
		if !grantAmount.MatchString(n) {
			return nil, ErrMetonClosed
		}
	}
	result := &MetonGiftReceipt{Scope: scope, Funds: MetonGiftFunds{v.Funds.State, v.Funds.Balance, v.Funds.Gift, v.Funds.Held, v.Funds.RefundHeld, v.Funds.Pending}, Retired: v.Retired, Effects: v.Effects}
	if t := v.Termination; t != nil {
		original := MetonGiftScope{MetonManagedClaim{1, t.Environment, t.Source, t.User, t.Account, t.Creation, t.Dispatch, t.Epoch}, t.RemoteUser, t.SourceMarker, t.Eligibility}
		final := &MetonGiftFinal{t.Decision, t.Registration, t.IdentityEvent, t.SecurityVersion, t.IdentityEpoch}
		if original != scope || !final.Valid() || t.Cutoff < 0 || t.RecordedAt.Before(time.Unix(0, 0)) || q.Final != nil && *q.Final != *final {
			return nil, ErrMetonClosed
		}
		result.Final, result.Cutoff = final, t.Cutoff
	} else if v.Effects != 0 || v.Retired != "0.00000000" || q.Final != nil && (v.Funds.State == "empty" || v.Funds.State == "gift_only" || v.Funds.State == "gift_scope_ready") {
		return nil, ErrMetonClosed
	}
	return result, nil
}
