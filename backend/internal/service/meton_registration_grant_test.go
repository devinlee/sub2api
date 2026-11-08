//go:build meton_managed

package service

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"testing"
)

type grantOfflineCache struct {
	BillingCache
	reads int
}

func (c *grantOfflineCache) GetUserBalance(context.Context, int64) (float64, error) {
	c.reads++
	return 0, errors.New("fixture redis unavailable")
}

func TestMetonGrantNativeCashWorkersClosed(t *testing.T) {
	s := new(PaymentService)
	ctx := context.Background()
	if o, e := s.CreateOrder(ctx, CreateOrderRequest{}); o != nil || !errors.Is(e, ErrMetonClosed) {
		t.Fatal("new payment")
	}
	for _, e := range []error{s.HandlePaymentNotification(ctx, nil, "fixture"), s.ExecuteBalanceFulfillment(ctx, 1), s.ExecuteSubscriptionFulfillment(ctx, 1)} {
		if !errors.Is(e, ErrMetonClosed) {
			t.Fatal("cash fulfillment")
		}
	}
	if p, r, e := s.PrepareRefund(ctx, 1, 1, "fixture", true, true); p != nil || r != nil || !errors.Is(e, ErrMetonClosed) {
		t.Fatal("refund preparation")
	}
	if r, e := s.ExecuteRefund(ctx, nil); r != nil || !errors.Is(e, ErrMetonClosed) {
		t.Fatal("external refund")
	}
	if r, e := s.QueryAndFinalizeRefund(ctx, 1); r != nil || !errors.Is(e, ErrMetonClosed) {
		t.Fatal("refund finalization")
	}
}

// 隔离构建中的原生消费、缓存预占和降级入口必须在第一次外部效果前拒绝。
func TestMetonGrantLegacyBillingClosed(t *testing.T) {
	ctx := context.Background()
	offline := new(grantOfflineCache)
	cache := &BillingCacheService{cache: offline}
	for _, sub := range []*UserSubscription{nil, {}} {
		if e := cache.CheckBillingEligibility(ctx, &User{}, &APIKey{}, &Group{}, sub, "openai"); !errors.Is(e, ErrMetonClosed) {
			t.Fatal("native eligibility")
		}
		if h, e := cache.ReserveInflight(ctx, &User{}, &Group{}, sub, 1); h != nil || !errors.Is(e, ErrMetonClosed) {
			t.Fatal("cache fallback")
		}
		if h, e := cache.ReserveFixedCharge(ctx, &User{}, &APIKey{}, &Group{}, sub, 1); h != nil || !errors.Is(e, ErrMetonClosed) {
			t.Fatal("fixed charge fallback")
		}
	}
	if ok, e := applyUsageBilling(ctx, "", nil, &postUsageBillingParams{}, &billingDeps{}, nil); ok || !errors.Is(e, ErrMetonClosed) {
		t.Fatal("degraded writer")
	}
	if r, e := new(UsageService).Create(ctx, CreateUsageLogRequest{}); r != nil || !errors.Is(e, ErrMetonClosed) {
		t.Fatal("legacy usage")
	}
	if offline.reads != 0 {
		t.Fatal("cache allowed to decide admission")
	}
}

func TestMetonGrantRolesAndMissingRepository(t *testing.T) {
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": "100000000000000000000001", "READ_KEY_ID": "100000000000000000000002",
		"GRANT_WRITE_KEY_ID": "100000000000000000000003", "GRANT_READ_KEY_ID": "100000000000000000000004"} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	s, ok := MetonSource()
	if !ok {
		t.Fatal("source")
	}
	if _, e := new(adminServiceImpl).RegistrationGrant(context.Background(), s, uuid.New(), uuid.New(), nil); !errors.Is(e, ErrMetonClosed) {
		t.Fatal("missing repo")
	}
	for _, env := range []string{"CREATE_KEY_ID", "READ_KEY_ID", "FUNDS_READ_KEY_ID", "CLOSE_KEY_ID", "INSPECT_KEY_ID", "ROTATE_KEY_ID", "ISSUE_KEY_ID", "GRANT_READ_KEY_ID"} {
		t.Run(env, func(t *testing.T) {
			t.Setenv("METON_MANAGED_"+env, "100000000000000000000003")
			live, _ := MetonSource()
			if _, ok := live.GrantKeyID(true); ok {
				t.Fatal("overlapping credentials")
			}
		})
	}
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s1-closed-v1")
	if _, ok := s.GrantKeyID(true); ok {
		t.Fatal("old mode")
	}
}
