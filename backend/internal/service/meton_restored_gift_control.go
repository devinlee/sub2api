package service

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/google/uuid"
)

type MetonRestoredGiftStore interface {
	Resolve(context.Context, MetonManagedSource, string, MetonRestoredGiftRequest, MetonRestoredGiftAccess, func() bool) (json.RawMessage, error)
}
type RestoredGiftKeyGeneration struct {
	Epoch       int64  `json:"epoch"`
	ReadID      string `json:"read_id"`
	ReconcileID string `json:"reconcile_id"`
	TerminateID string `json:"terminate_id,omitempty"`
}
type RestoredGiftKeyHistory struct {
	FormatVersion int                         `json:"format_version"`
	Environment   string                      `json:"environment"`
	Source        string                      `json:"source"`
	Generations   []RestoredGiftKeyGeneration `json:"generations"`
}
type restoredGiftIDs struct{ read, write, terminate string }
type MetonRestoredGiftControl struct {
	source  MetonManagedSource
	ids     restoredGiftIDs
	retired map[string]bool
	epochs  map[int64]bool
	store   MetonRestoredGiftStore
	slots   chan struct{}
	timeout time.Duration
}

func restoredGiftServiceIDs(retired map[string]bool) (restoredGiftIDs, bool) {
	ids := restoredGiftIDs{os.Getenv("METON_MANAGED_RESTORED_GIFT_READ_KEY_ID"), os.Getenv("METON_MANAGED_RESTORED_GIFT_RECONCILE_KEY_ID"), os.Getenv("METON_MANAGED_RESTORED_GIFT_TERMINATE_KEY_ID")}
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || !metonKeyID.MatchString(ids.read) || !metonKeyID.MatchString(ids.write) || ids.read == ids.write {
		return ids, false
	}
	if ids.terminate != "" && (!metonKeyID.MatchString(ids.terminate) || ids.terminate == ids.read || ids.terminate == ids.write) {
		return ids, false
	}
	counts := map[string]int{}
	for _, entry := range os.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if ok && strings.HasPrefix(name, "METON_MANAGED_") && strings.HasSuffix(name, "_KEY_ID") {
			if retired[value] {
				return ids, false
			}
			counts[value]++
		}
	}
	return ids, counts[ids.read] == 1 && counts[ids.write] == 1 && (ids.terminate == "" || counts[ids.terminate] == 1)
}

/** 固定当前实例和两种最小身份；外部公开身份历史不能让旧 ID 再进入当前配置。 */
func NewMetonRestoredGiftControl(source MetonManagedSource, store MetonRestoredGiftStore, parallel int, timeout time.Duration, h *RestoredGiftKeyHistory) (*MetonRestoredGiftControl, error) {
	now, ok := MetonSource()
	ids, valid := restoredGiftServiceIDs(nil)
	if !ok || now != source || !valid || source.Epoch <= 1 || store == nil || parallel < 1 || parallel > 16 || timeout < time.Millisecond || timeout > 30*time.Second || h == nil {
		return nil, ErrMetonClosed
	}
	n := len(h.Generations)
	if (h.FormatVersion != 1 && h.FormatVersion != 2) || h.FormatVersion == 1 && ids.terminate != "" || h.Environment != source.Environment || h.Source != source.Source || n < 2 || n > 4096 || h.Generations[0].Epoch != 1 ||
		h.Generations[n-1] != (RestoredGiftKeyGeneration{source.Epoch, ids.read, ids.write, ids.terminate}) {
		return nil, ErrMetonClosed
	}
	retired, seen, epochs := map[string]bool{}, map[string]bool{}, map[int64]bool{}
	var epoch int64
	for i, g := range h.Generations {
		if g.Epoch <= epoch || (g.ReadID == "") != (g.ReconcileID == "") || h.FormatVersion == 1 && g.TerminateID != "" || g.TerminateID != "" && g.ReadID == "" {
			return nil, ErrMetonClosed
		}
		epoch = g.Epoch
		epochs[epoch] = true
		for _, id := range []string{g.ReadID, g.ReconcileID, g.TerminateID} {
			if id == "" {
				continue
			}
			if !metonKeyID.MatchString(id) || seen[id] {
				return nil, ErrMetonClosed
			}
			seen[id] = true
			if i < n-1 {
				retired[id] = true
			}
		}
	}
	if active, valid := restoredGiftServiceIDs(retired); !valid || active != ids {
		return nil, ErrMetonClosed
	}
	return &MetonRestoredGiftControl{source, ids, retired, epochs, store, make(chan struct{}, parallel), timeout}, nil
}

func (c *MetonRestoredGiftControl) Allows(action string, p *adminaccess.Principal) bool {
	if c == nil || p == nil || p.CreatorID < 1 || p.KeyRevision.IsZero() {
		return false
	}
	id := ""
	switch action {
	case "inspect":
		id = c.ids.read
	case "reconcile":
		id = c.ids.write
	case "terminate":
		id = c.ids.terminate
	default:
		return false
	}
	return id != "" && p.KeyID == id && adminaccess.RouteAllowed(p.Policy, "POST", "/api/v1/admin"+RestoredGiftRoute+action)
}

/** 一次请求只执行一次原操作，提交未知不重发，交付前再认证当前管理身份。 */
func (c *MetonRestoredGiftControl) Execute(ctx context.Context, creation uuid.UUID, action string, q MetonRestoredGiftRequest, p *adminaccess.Principal, key string, deliver func(context.Context) bool) (*MetonRestoredGiftReceipt, error) {
	if !c.Allows(action, p) || deliver == nil {
		return nil, ErrMetonClosed
	}
	raw, e := json.Marshal(q)
	if _, err := ReadMetonRestoredGift(action, raw); e != nil || err != nil {
		return nil, ErrMetonClosed
	}
	o := q.Original.Scope
	if creation != o.Operation || o.Environment != c.source.Environment || o.Source != c.source.Source || q.Epoch != c.source.Epoch || !c.epochs[o.Epoch] {
		return nil, ErrMetonClosed
	}
	now := time.Now()
	until := time.UnixMilli(q.UntilMS)
	if !until.After(now) || until.After(now.Add(30*time.Second)) {
		return nil, ErrMetonClosed
	}
	until = earlierCorrectionTime(until, now.Add(c.timeout))
	if d, ok := ctx.Deadline(); ok {
		until = earlierCorrectionTime(until, d)
	}
	if p.KeyExpiresAt != nil {
		until = earlierCorrectionTime(until, *p.KeyExpiresAt)
	}
	access, ok := BindMetonRestoredGiftAccess(key, p.KeyID, p.CreatorID, p.KeyRevision, until, action, q)
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
		ids, valid := restoredGiftServiceIDs(c.retired)
		return ok && live == c.source && valid && ids == c.ids && bounded.Err() == nil && time.Now().Before(access.Until)
	}
	if !guard() {
		return nil, ErrMetonClosed
	}
	result, err := c.store.Resolve(bounded, c.source, action, q, access, guard)
	if err != nil || !guard() || !deliver(bounded) || !guard() {
		return nil, ErrMetonClosed
	}
	return restoredGiftReceipt(result, q, action)
}
