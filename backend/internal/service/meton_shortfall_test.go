//go:build meton_managed && unit

package service

import (
	"context"
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/google/uuid"
)

type shortfallControlledStore struct {
	resolve func(context.Context, func(context.Context) error) (json.RawMessage, error)
}

/** 仅控制完成时序；真实 SQL、HTTP 和扣款另由局部集成用例覆盖。 */
func (s shortfallControlledStore) Resolve(ctx context.Context, _ MetonManagedSource, _ uuid.UUID, _ string, _ metonmodel.ShortfallRequest, guard func(context.Context) error) (json.RawMessage, error) {
	return s.resolve(ctx, guard)
}

/** 取消不提前释放仍运行的名额；配置换代后的迟到响应、超时均不能自动重发。 */
func TestShortfallControlConcurrencyAndRevocation(t *testing.T) {
	for name, value := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "SHORTFALL_APPLY_KEY_ID": strings.Repeat("d", 24), "SHORTFALL_READ_KEY_ID": strings.Repeat("e", 24)} {
		t.Setenv("METON_MANAGED_"+name, value)
	}
	source, ok := MetonSource()
	if !ok {
		t.Fatal("隔离来源缺失")
	}
	creation, operation := uuid.New(), uuid.New()
	bound := 2
	q := metonmodel.ShortfallRequest{Version: 1, Epoch: 1, UntilMS: time.Now().Add(25 * time.Second).UnixMilli(),
		Admission: metonmodel.Admission{Version: 1, AcceptedEpoch: 1,
			Origin:  metonfee.Origin{Environment: "s2-isolated", Source: "s2-managed", User: uuid.NewString(), Account: uuid.NewString(), SourceMarker: uuid.NewString(), Caller: "meton.chat.v1", OperationID: operation.String(), SourceRequestID: uuid.NewString()},
			Request: metonmodel.Request{Protocol: "responses", Model: "fixture", DigestVersion: 1, InputDigest: strings.Repeat("a", 64), InputBound: &bound, OutputBound: 1},
			Pricing: metonmodel.Pricing{Version: "fixture-v1", Unit: "credit", Quote: "3.00000000"}},
		ShortfallSelection: metonmodel.ShortfallSelection{CommandID: uuid.NewString(), CaseID: uuid.NewString(), AttemptID: uuid.NewString(), ApprovalDigest: strings.Repeat("f", 64), BasisEvent: uuid.NewString()}}
	invoke := func(ctx context.Context, c *MetonShortfallControl) error {
		_, err := c.Execute(ctx, source, creation, q.Admission.Origin.Caller, operation, "apply", q)
		return err
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	store := shortfallControlledStore{resolve: func(ctx context.Context, guard func(context.Context) error) (json.RawMessage, error) {
		if calls.Add(1) == 1 {
			close(entered)
			<-release
		}
		return nil, nil
	}}
	control := NewMetonShortfallControl(store, 1, time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- invoke(ctx, control) }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("没有进入受控调用")
	}
	cancel()
	if err := invoke(context.Background(), control); err == nil || calls.Load() != 1 {
		t.Fatal("取消提前释放仍运行的名额")
	}
	close(release)
	if err := <-done; err == nil {
		t.Fatal("取消后迟到结果被交付")
	}
	if err := invoke(context.Background(), control); err != nil || calls.Load() != 2 {
		t.Fatal("实际结束后名额未释放", err)
	}

	entered, release = make(chan struct{}), make(chan struct{})
	store.resolve = func(context.Context, func(context.Context) error) (json.RawMessage, error) {
		close(entered)
		<-release
		return nil, nil
	}
	control = NewMetonShortfallControl(store, 1, time.Second)
	go func() { done <- invoke(context.Background(), control) }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("没有进入换代检查")
	}
	t.Setenv("METON_MANAGED_EPOCH", "2")
	close(release)
	if err := <-done; err == nil {
		t.Fatal("旧代次迟到响应被交付")
	}
	t.Setenv("METON_MANAGED_EPOCH", "1")
	var timed atomic.Int32
	store.resolve = func(ctx context.Context, _ func(context.Context) error) (json.RawMessage, error) {
		timed.Add(1)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	control = NewMetonShortfallControl(store, 1, 30*time.Millisecond)
	if err := invoke(context.Background(), control); err == nil || timed.Load() != 1 {
		t.Fatal("超时发生自动重发")
	}
	if err := invoke(context.Background(), nil); err == nil {
		t.Fatal("缺实现仍可执行")
	}
	for _, name := range []string{"CREATE", "READ", "RESULT_READ", "SHORTFALL_READ"} {
		name := name
		t.Run(name, func(t *testing.T) {
			t.Setenv("METON_MANAGED_"+name+"_KEY_ID", strings.Repeat("d", 24))
			if _, enabled := source.ShortfallControlID("apply"); enabled {
				t.Fatal("兼任身份被接受")
			}
		})
	}
}
