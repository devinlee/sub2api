package service

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
)

type MetonFinancialStore interface {
	Read(context.Context, metonmodel.FinancialScope, metonmodel.FinancialAccess) (json.RawMessage, error)
	Confirm(context.Context, metonmodel.FinancialScope, metonmodel.FinancialAccess) error
}
type FinancialKeyGeneration struct {
	Epoch int64  `json:"epoch"`
	KeyID string `json:"key_id"`
}
type FinancialKeyHistory struct {
	FormatVersion int                      `json:"format_version"`
	Environment   string                   `json:"environment"`
	Source        string                   `json:"source"`
	Generations   []FinancialKeyGeneration `json:"generations"`
}
type MetonFinancialControl struct {
	source  MetonManagedSource
	keyID   string
	retired map[string]bool
	store   MetonFinancialStore
	slots   chan struct{}
	timeout time.Duration
}

/** 固定本实例的观察身份，禁止与任一托管用途或恢复前身份混用。 */
func financialID(retired map[string]bool) (string, bool) {
	id := os.Getenv("METON_MANAGED_FINANCIAL_KEY_ID")
	if !metonKeyID.MatchString(id) || os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" {
		return "", false
	}
	count := 0
	for _, entry := range os.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if ok && strings.HasPrefix(name, "METON_MANAGED_") && strings.HasSuffix(name, "_KEY_ID") {
			if retired[value] {
				return "", false
			}
			if value == id {
				count++
			}
		}
	}
	return id, count == 1
}

/** 外部历史只记录公开 ID。恢复后必须换 ID，旧库和旧权限不能单独恢复入口。 */
func NewMetonFinancialControl(source MetonManagedSource, store MetonFinancialStore, parallel int, timeout time.Duration, h *FinancialKeyHistory) (*MetonFinancialControl, error) {
	current, ok := MetonSource()
	id, valid := financialID(nil)
	if !ok || current != source || !valid || store == nil || parallel < 1 || parallel > 4 || timeout < time.Millisecond || timeout > 5*time.Second {
		return nil, ErrMetonClosed
	}
	retired := map[string]bool{}
	if h == nil {
		if source.Epoch != 1 {
			return nil, ErrMetonClosed
		}
	} else {
		n := len(h.Generations)
		if h.FormatVersion != 1 || h.Environment != source.Environment || h.Source != source.Source || n == 0 || n > 4096 || h.Generations[0].Epoch != 1 || h.Generations[n-1] != (FinancialKeyGeneration{source.Epoch, id}) {
			return nil, ErrMetonClosed
		}
		seen := map[string]bool{}
		var epoch int64
		for i, g := range h.Generations {
			if g.Epoch <= epoch {
				return nil, ErrMetonClosed
			}
			epoch = g.Epoch
			if g.KeyID == "" {
				continue
			}
			if !metonKeyID.MatchString(g.KeyID) || seen[g.KeyID] {
				return nil, ErrMetonClosed
			}
			seen[g.KeyID] = true
			if i < n-1 {
				retired[g.KeyID] = true
			}
		}
	}
	if key, ok := financialID(retired); !ok || key != id {
		return nil, ErrMetonClosed
	}
	return &MetonFinancialControl{source, id, retired, store, make(chan struct{}, parallel), timeout}, nil
}

func (c *MetonFinancialControl) Allows(p *adminaccess.Principal) bool {
	return c != nil && p != nil && p.CreatorID > 0 && !p.KeyRevision.IsZero() && p.KeyID == c.keyID && adminaccess.RouteAllowed(p.Policy, "GET", "/api/v1/admin"+metonmodel.FinancialRoute)
}

/** 名额直到真实读取与复核结束才释放；超时、停供和撤销都不返回过期样本。 */
func (c *MetonFinancialControl) Observe(ctx context.Context, p *adminaccess.Principal, key string, deliver func(context.Context) bool) (*metonmodel.FinancialObservation, error) {
	if !c.Allows(p) || deliver == nil {
		return nil, ErrMetonClosed
	}
	select {
	case c.slots <- struct{}{}:
		defer func() { <-c.slots }()
	default:
		return nil, ErrMetonClosed
	}
	now := time.Now()
	until := now.Add(c.timeout)
	if d, ok := ctx.Deadline(); ok {
		until = earlierCorrectionTime(until, d)
	}
	if p.KeyExpiresAt != nil {
		until = earlierCorrectionTime(until, *p.KeyExpiresAt)
	}
	scope := metonmodel.FinancialScope{Environment: c.source.Environment, Source: c.source.Source, Epoch: c.source.Epoch}
	access, ok := metonmodel.BindFinancialAccess(key, p.KeyID, p.CreatorID, p.KeyRevision, until, scope)
	if !ok || !access.Until.After(now) {
		return nil, ErrMetonClosed
	}
	bounded, cancel := context.WithDeadline(ctx, access.Until)
	defer cancel()
	current := func() bool {
		s, live := MetonSource()
		id, valid := financialID(c.retired)
		return live && s == c.source && valid && id == c.keyID && bounded.Err() == nil && time.Now().Before(access.Until)
	}
	if !current() {
		return nil, ErrMetonClosed
	}
	raw, err := c.store.Read(bounded, scope, access)
	if err != nil || !current() {
		return nil, ErrMetonClosed
	}
	sample, err := metonmodel.ReadFinancialObservation(raw, scope, time.Now())
	if err != nil || !deliver(bounded) || !current() {
		return nil, ErrMetonClosed
	}
	// 用新的 READ COMMITTED 语句核对，避免取样等锁时仍沿用恢复前的快照。
	if c.store.Confirm(bounded, scope, access) != nil || !current() || !time.Now().Before(sample.Snapshot.ValidUntil) {
		return nil, ErrMetonClosed
	}
	return sample, nil
}
