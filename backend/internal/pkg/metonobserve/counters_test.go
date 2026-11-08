package metonobserve

import (
	"encoding/json"
	"errors"
	"math"
	"strings"
	"sync"
	"testing"
)

/** 安装、范围、换代和重复关闭必须互相独立，旧清理不能清掉新实例。 */
func TestRejectionObservationScopeAndLifecycle(t *testing.T) {
	scope := Scope{"s2-isolated", "s2-managed", 1}
	for _, bad := range []Scope{{}, {"user/request", "s", 1}, {"e", "s", 0}} {
		if c, err := Install(bad, "one"); err == nil || c != nil {
			t.Fatal("invalid scope installed")
		}
	}
	c, err := Install(scope, "one")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := Install(scope, "two"); err == nil {
		t.Fatal("live observer overwritten")
	}
	Record(Scope{"other", scope.Source, 1}, RepeatAttempt)
	Record(Scope{scope.Environment, scope.Source, 2}, RepeatAttempt)
	Record(scope, Kind(255))
	Claim(scope, true, nil)
	Claim(scope, false, nil)
	Claim(scope, true, errors.New("unknown"))
	s, ok := c.Snapshot()
	if !ok || s.Counts[RepeatAttempt].Value != 0 || s.Counts[SendNotGranted].Value != 1 || s.Counts[SendQueryFailed].Value != 1 {
		t.Fatal("wrong classification", s)
	}
	c.Close()
	if _, ok := c.Snapshot(); ok {
		t.Fatal("closed snapshot available")
	}
	newScope := scope
	newScope.Epoch++
	next, err := Install(newScope, "one")
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	c.Close()
	Record(scope, RepeatAttempt)
	Record(newScope, RepeatAttempt)
	n, ok := next.Snapshot()
	if !ok || n.Boot == s.Boot || n.Counts[RepeatAttempt].Value != 1 || n.Counts[SendNotGranted].Value != 0 {
		t.Fatal("old observer affects new scope")
	}
}

/** 高并发只更新固定数组，没有逐请求事件、标签或日志队列。 */
func TestRejectionObservationConcurrentTotals(t *testing.T) {
	scope := Scope{"s2-isolated", "s2-managed", 1}
	c, err := Install(scope, "one")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var workers sync.WaitGroup
	for i := 0; i < 32; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for n := 0; n < 1000; n++ {
				for k := Kind(0); k < kindCount; k++ {
					Record(scope, k)
				}
			}
		}()
	}
	workers.Wait()
	s, ok := c.Snapshot()
	if !ok {
		t.Fatal("missing snapshot")
	}
	for _, count := range s.Counts {
		if count.Value != 32000 {
			t.Fatal("concurrent count lost", count)
		}
	}
}

/** 饱和不回绕，JSON 保留整数字符串；载荷只有固定分类和部署观察身份。 */
func TestRejectionObservationSaturationAndShape(t *testing.T) {
	scope := Scope{"s2-isolated", "s2-managed", 1}
	c, err := Install(scope, "one")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.counts[RepeatAttempt] = math.MaxUint64 - 1
	Record(scope, RepeatAttempt)
	Record(scope, RepeatAttempt)
	s, ok := c.Snapshot()
	if !ok || !s.Saturated || s.Counts[RepeatAttempt].Value != math.MaxUint64 {
		t.Fatal("counter wrapped")
	}
	raw, err := json.Marshal(s)
	if err != nil || !strings.Contains(string(raw), `"value":"18446744073709551615"`) {
		t.Fatal("counter precision lost")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(fields) != 8 {
		t.Fatal("unexpected observation payload")
	}
	for _, forbidden := range []string{"user", "request", "key", "amount", "prompt"} {
		if strings.Contains(string(raw), `"`+forbidden+`"`) {
			t.Fatal("private field in observation")
		}
	}
}
