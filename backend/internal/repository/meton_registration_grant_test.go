//go:build meton_managed

package repository

import (
	"context"
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
	"testing"
)

func TestMetonGrantNativeRepositoryClosed(t *testing.T) {
	ctx := context.Background()
	var r usageBillingRepository
	if v, e := r.Apply(ctx, &service.UsageBillingCommand{}); v != nil || !errors.Is(e, service.ErrMetonClosed) {
		t.Fatal("old settlement")
	}
	for _, call := range []func(context.Context, *service.BatchImageBalanceHoldCommand) (*service.BatchImageBalanceHoldResult, error){
		r.ReserveBatchImageBalance, r.CaptureBatchImageBalance, r.ReleaseBatchImageBalance} {
		if v, e := call(ctx, &service.BatchImageBalanceHoldCommand{}); v != nil || !errors.Is(e, service.ErrMetonClosed) {
			t.Fatal("native image hold")
		}
	}
	if v, e := new(userRepository).RegistrationGrant(ctx, service.MetonManagedSource{}, uuid.New(), uuid.New(), nil); v != nil || !errors.Is(e, service.ErrMetonClosed) {
		t.Fatal("missing sql")
	}
}
