package service

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/google/uuid"
)

type MetonShortfallStore interface {
	Resolve(context.Context, MetonManagedSource, uuid.UUID, string, metonmodel.ShortfallRequest, func(context.Context) error) (json.RawMessage, error)
}

type MetonShortfallControl struct {
	store   MetonShortfallStore
	slots   chan struct{}
	timeout time.Duration
}

/** 两种身份彼此互斥，也不能和已有托管账号、凭据或资金身份共用。 */
func (s MetonManagedSource) ShortfallControlID(action string) (string, bool) {
	purpose := map[string]string{"apply": "SHORTFALL_APPLY", "resolution": "SHORTFALL_READ"}[action]
	if purpose == "" || os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" {
		return "", false
	}
	seen := map[string]bool{}
	for _, name := range []string{"SHORTFALL_APPLY", "SHORTFALL_READ"} {
		key := "METON_MANAGED_" + name + "_KEY_ID"
		id := os.Getenv(key)
		if !metonKeyID.MatchString(id) || seen[id] || id == s.CreateKeyID || id == s.ReadKeyID {
			return "", false
		}
		seen[id] = true
		for _, entry := range os.Environ() {
			k, v, ok := strings.Cut(entry, "=")
			if ok && k != key && strings.HasPrefix(k, "METON_MANAGED_") && strings.HasSuffix(k, "_KEY_ID") && v == id {
				return "", false
			}
		}
	}
	return os.Getenv("METON_MANAGED_" + purpose + "_KEY_ID"), true
}

/** 缺少实现或预算时关闭；不回退到普通用户接口。 */
func NewMetonShortfallControl(store MetonShortfallStore, parallel int, timeout time.Duration) *MetonShortfallControl {
	if store == nil || parallel < 1 || parallel > 16 || timeout <= 0 || timeout > 30*time.Second {
		return nil
	}
	return &MetonShortfallControl{store: store, slots: make(chan struct{}, parallel), timeout: timeout}
}

/** Execute 只进入指定执行或只读分支，超时与查无不改成重试或新的处置。 */
func (s *MetonShortfallControl) Execute(ctx context.Context, source MetonManagedSource, creation uuid.UUID, caller string, operation uuid.UUID, action string, q metonmodel.ShortfallRequest) (json.RawMessage, error) {
	raw, _ := json.Marshal(q)
	checked, err := metonmodel.ReadShortfall(raw)
	id, allowed := source.ShortfallControlID(action)
	if s == nil || s.store == nil || err != nil || !allowed || creation == uuid.Nil || operation == uuid.Nil ||
		checked.Admission.Origin.Environment != source.Environment || checked.Admission.Origin.Source != source.Source || checked.Epoch != source.Epoch ||
		checked.Admission.Origin.Caller != caller || checked.Admission.Origin.OperationID != operation.String() {
		return nil, ErrMetonClosed
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		return nil, ErrMetonClosed
	}
	deadline := time.UnixMilli(q.UntilMS)
	if maximum := time.Now().Add(s.timeout); maximum.Before(deadline) {
		deadline = maximum
	}
	ctx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()
	guard := func(ctx context.Context) error {
		live, ok := MetonSource()
		current, enabled := source.ShortfallControlID(action)
		if ctx.Err() != nil || !ok || live != source || !enabled || current != id || !q.Current(time.Now()) {
			return ErrMetonClosed
		}
		return nil
	}
	if guard(ctx) != nil {
		return nil, ErrMetonClosed
	}
	raw, err = s.store.Resolve(ctx, source, creation, action, *checked, guard)
	if err != nil || guard(ctx) != nil {
		return nil, ErrMetonClosed
	}
	if len(raw) == 0 {
		return nil, nil
	}
	r, err := metonmodel.ReadShortfallReceipt(raw)
	if err != nil || r.Epoch != source.Epoch || r.Origin != q.Admission.Origin || r.ShortfallSelection != q.ShortfallSelection ||
		r.Original.Reference.Item.PriceVersion != q.Admission.Pricing.Version || r.Original.Reference.Item.Unit != q.Admission.Pricing.Unit {
		return nil, ErrMetonClosed
	}
	return raw, nil
}
