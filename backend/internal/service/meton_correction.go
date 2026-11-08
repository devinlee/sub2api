package service

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/google/uuid"
)

type MetonCorrectionStore interface {
	ResolveCorrection(context.Context, MetonManagedSource, uuid.UUID, string, metonmodel.CorrectionRequest, metonmodel.CorrectionAccess,
		func() bool) (json.RawMessage, error)
}

type correctionIDs struct{ read, approve, apply string }

func (ids correctionIDs) forAction(action string) string {
	switch action {
	case "basis", "resolution":
		return ids.read
	case "approve":
		return ids.approve
	case "apply":
		return ids.apply
	}
	return ""
}

func correctionServiceIDs(s MetonManagedSource, retired map[string]bool) (correctionIDs, bool) {
	var ids correctionIDs
	seen := map[string]int{}
	mode := ""
	for _, entry := range os.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		switch name {
		case "METON_MANAGED_FUNDS_MODE":
			mode = value
		case "METON_MANAGED_CORRECTION_READ_KEY_ID":
			ids.read = value
		case "METON_MANAGED_CORRECTION_APPROVE_KEY_ID":
			ids.approve = value
		case "METON_MANAGED_CORRECTION_APPLY_KEY_ID":
			ids.apply = value
		}
		if strings.HasPrefix(name, "METON_MANAGED_") && strings.HasSuffix(name, "_KEY_ID") {
			if retired[value] {
				return ids, false
			}
			seen[value]++
		}
	}
	if mode != "s2-source-v1" {
		return ids, false
	}
	for _, v := range []string{ids.read, ids.approve, ids.apply} {
		if !metonKeyID.MatchString(v) || v == s.CreateKeyID || v == s.ReadKeyID || seen[v] != 1 {
			return ids, false
		}
	}
	return ids, true
}

type MetonCorrectionControl struct {
	history *correctionHistory
	source  MetonManagedSource
	ids     correctionIDs
	store   MetonCorrectionStore
	slots   chan struct{}
	timeout time.Duration
}

/** 启动时固定三种服务身份。来源、代次或身份变动后该实例不能接手新配置。 */
func NewMetonCorrectionControl(source MetonManagedSource, store MetonCorrectionStore, parallel int, timeout time.Duration, history *CorrectionKeyHistory) (*MetonCorrectionControl, error) {
	current, live := MetonSource()
	ids, ok := correctionServiceIDs(source, nil)
	if store == nil || !live || current != source || !ok || parallel < 1 || parallel > 16 || timeout <= 0 || timeout > 30*time.Second {
		return nil, ErrMetonClosed
	}
	h, accepted := history.verified(source, ids)
	if !accepted {
		return nil, ErrMetonClosed
	}
	if active, ok := correctionServiceIDs(source, h.retired); !ok || active != ids {
		return nil, ErrMetonClosed
	}
	return &MetonCorrectionControl{source: source, ids: ids, history: h, store: store, slots: make(chan struct{}, parallel), timeout: timeout}, nil
}

func (c *MetonCorrectionControl) Allows(action string, p *adminaccess.Principal) bool {
	if c == nil || p == nil || p.CreatorID <= 0 || p.KeyRevision.IsZero() || p.KeyID == "" || p.KeyID != c.ids.forAction(action) {
		return false
	}
	return adminaccess.RouteAllowed(p.Policy, "POST", "/api/v1/admin"+metonmodel.CorrectionRoute+action)
}

/** 每个动作使用独立的来源权限；持有旧原受理允许核对，写动作只接受当前代次。 */
func (c *MetonCorrectionControl) Execute(ctx context.Context, creation uuid.UUID, caller string, operation uuid.UUID, action string,
	q metonmodel.CorrectionRequest, p *adminaccess.Principal, nativeKey string, deliver func(context.Context) bool) (*metonmodel.CorrectionEnvelope, error) {
	if !c.Allows(action, p) || creation == uuid.Nil || operation == uuid.Nil || deliver == nil {
		return nil, ErrMetonClosed
	}
	raw, err := json.Marshal(q)
	if _, valid := metonmodel.ReadCorrection(action, raw); err != nil || valid != nil {
		return nil, ErrMetonClosed
	}
	o := q.Admission.Origin
	now := time.Now()
	until := time.UnixMilli(q.UntilMS)
	if o.Environment != c.source.Environment || o.Source != c.source.Source || q.Epoch != c.source.Epoch || !c.history.epochs[q.Admission.AcceptedEpoch] ||
		o.Caller != caller || o.OperationID != operation.String() || !until.After(now) || until.After(now.Add(30*time.Second)) {
		return nil, ErrMetonClosed
	}
	until = earlierCorrectionTime(until, now.Add(c.timeout))
	if d, ok := ctx.Deadline(); ok {
		until = earlierCorrectionTime(until, d)
	}
	if p.KeyExpiresAt != nil {
		until = earlierCorrectionTime(until, *p.KeyExpiresAt)
	}
	if q.Review != nil {
		until = earlierCorrectionTime(until, time.UnixMilli(q.Review.ValidUntilMS))
	}
	access, ok := metonmodel.BindCorrectionAccess(nativeKey, p.KeyID, p.CreatorID, p.KeyRevision, until, action, &q)
	if !ok || !access.Until.After(now) {
		return nil, ErrMetonClosed
	}
	select {
	case c.slots <- struct{}{}:
		defer func() { <-c.slots }()
	default:
		return nil, ErrMetonClosed
	}
	bounded, cancel := context.WithDeadline(ctx, access.Until)
	defer cancel()
	guard := func() bool {
		live, ok := MetonSource()
		current, enabled := correctionServiceIDs(c.source, c.history.retired)
		return ok && live == c.source && enabled && current == c.ids && bounded.Err() == nil && time.Now().Before(access.Until)
	}
	if !guard() {
		return nil, ErrMetonClosed
	}
	data, err := c.store.ResolveCorrection(bounded, c.source, creation, action, q, access, guard)
	if err != nil || !guard() || !deliver(bounded) || !guard() {
		return nil, ErrMetonClosed
	}
	if data == nil {
		return nil, nil
	}
	if !json.Valid(data) {
		return nil, ErrMetonClosed
	}
	return &metonmodel.CorrectionEnvelope{Version: 1, Action: action, Epoch: c.source.Epoch, Origin: o, Data: data}, nil
}

func earlierCorrectionTime(a, b time.Time) time.Time {
	if b.Before(a) {
		return b
	}
	return a
}
