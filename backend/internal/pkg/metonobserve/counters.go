// Package metonobserve 仅观察固定拒绝边界；不持有账号、模型正文、凭据或账本连接。
package metonobserve

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"math"
	"regexp"
	"sync"
	"sync/atomic"
	"time"
)

type Kind uint8

const (
	RepeatAttempt Kind = iota
	SendNotGranted
	SendQueryFailed
	RegistrationConflict
	kindCount
)

var names = [kindCount]string{"repeat_attempt", "send_not_granted", "send_query_failed", "registration_conflict"}
var label = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,120}$`)
var active atomic.Pointer[Collector]
var ErrConfiguration = errors.New("source observation unavailable")

type Scope struct {
	Environment string `json:"environment"`
	Source      string `json:"source"`
	Epoch       int64  `json:"epoch"`
}

/** Valid 只接受部署范围；不允许无限标签或原用户标识作为类别。 */
func (s Scope) Valid() bool {
	return label.MatchString(s.Environment) && label.MatchString(s.Source) && s.Epoch > 0
}

type Count struct {
	Kind  string `json:"kind"`
	Value uint64 `json:"value,string"`
}
type Snapshot struct {
	Version    int              `json:"format_version"`
	Scope      Scope            `json:"scope"`
	Replica    string           `json:"replica"`
	Boot       string           `json:"boot"`
	StartedAt  time.Time        `json:"started_at"`
	ObservedAt time.Time        `json:"observed_at"`
	Saturated  bool             `json:"saturated"`
	Counts     [kindCount]Count `json:"counts"`
}
type Collector struct {
	mu        sync.Mutex
	scope     Scope
	replica   string
	boot      string
	started   time.Time
	closed    bool
	saturated bool
	counts    [kindCount]uint64
}

/** Install 显式装配一个进程观察者；不覆盖尚未关闭的实例，也不从旧日志恢复计数。 */
func Install(scope Scope, replica string) (*Collector, error) {
	if !scope.Valid() || !label.MatchString(replica) {
		return nil, ErrConfiguration
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return nil, ErrConfiguration
	}
	c := &Collector{scope: scope, replica: replica, boot: hex.EncodeToString(random[:]), started: time.Now().UTC()}
	if !active.CompareAndSwap(nil, c) {
		return nil, ErrConfiguration
	}
	return c, nil
}

/** Record 固定数量的内存累加；不执行外部回调、日志、文件、网络或资金操作。 */
func Record(scope Scope, kind Kind) {
	c := active.Load()
	if c == nil || kind >= kindCount || c.scope != scope {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if c.counts[kind] == math.MaxUint64 {
		c.saturated = true
		return
	}
	c.counts[kind]++
}

/** Claim 只描述一次已执行查询的返回；错误不等于确定重复，更不能恢复发送资格。 */
func Claim(scope Scope, first bool, err error) {
	if err != nil {
		Record(scope, SendQueryFailed)
	} else if !first {
		Record(scope, SendNotGranted)
	}
}

/** Snapshot 同一锁内读取全部固定分类；关闭后的零值不能冒充有效观察。 */
func (c *Collector) Snapshot() (Snapshot, bool) {
	if c == nil {
		return Snapshot{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Snapshot{}, false
	}
	s := Snapshot{Version: 1, Scope: c.scope, Replica: c.replica, Boot: c.boot, StartedAt: c.started, ObservedAt: time.Now().UTC(), Saturated: c.saturated}
	for i, name := range names {
		s.Counts[i] = Count{Kind: name, Value: c.counts[i]}
	}
	return s, true
}

/** Close 幂等退役；旧句柄的迟到关闭不能清掉后装配的新观察者。 */
func (c *Collector) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()
	active.CompareAndSwap(c, nil)
}
