package service

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"testing"
	"time"
)

type metonRotationAuthStub struct {
	APIKeyRepository
	allowed       bool
	unavailable   bool
	currentCalls  int
	originalCalls int
}

func (s *metonRotationAuthStub) GetByKeyForAuth(ctx context.Context, key string) (*APIKey, error) {
	s.originalCalls++
	return &APIKey{ID: 21, UserID: 12, Status: "active"}, nil
}
func (s *metonRotationAuthStub) CurrentManagedKey(ctx context.Context, source MetonKeySource, key, user int64, hash string) (bool, error) {
	s.currentCalls++
	if s.unavailable {
		return false, errors.New("unavailable")
	}
	return s.allowed && source.Epoch == 1 && key == 21 && user == 12 && len(hash) == 64, nil
}
func TestMetonManagedRotationChecksLiveSourceEvenForPreviouslyActiveKey(t *testing.T) {
	t.Setenv("METON_MANAGED_ENVIRONMENT", "test")
	t.Setenv("METON_MANAGED_SOURCE", "source")
	t.Setenv("METON_MANAGED_EPOCH", "1")
	names := []string{"METON_MANAGED_CREATE_KEY_ID", "METON_MANAGED_READ_KEY_ID", "METON_MANAGED_ISSUE_KEY_ID", "METON_MANAGED_INSPECT_KEY_ID", "METON_MANAGED_ROTATE_KEY_ID"}
	ids := []string{"000000000000000000000001", "000000000000000000000002", "000000000000000000000003", "000000000000000000000004", "000000000000000000000005"}
	for i, n := range names {
		t.Setenv(n, ids[i])
	}
	db := &metonRotationAuthStub{allowed: true}
	service := &APIKeyService{apiKeyRepo: db}
	key := "test-key-not-a-real-secret"
	if _, err := service.GetByKey(context.Background(), key); err != nil {
		t.Fatal("live fixture refused")
	}
	db.allowed = false
	if _, err := service.GetByKey(context.Background(), key); err == nil {
		t.Fatal("stale active row accepted")
	}
	db.allowed = true
	db.unavailable = true
	if _, err := service.GetByKey(context.Background(), key); err == nil {
		t.Fatal("source outage opened old credentials")
	}
	if db.originalCalls != 3 || db.currentCalls != 3 {
		t.Fatal("a cached grant skipped the live read")
	}
	source, _ := CurrentMetonKeySource()
	if _, ok := source.RotationID(); !ok {
		t.Fatal("distinct fixture key rejected")
	}
	t.Setenv("METON_MANAGED_ROTATE_KEY_ID", source.InspectID)
	if _, ok := source.RotationID(); ok {
		t.Fatal("read acquired rotation rights")
	}
	now := time.Now()
	c := MetonKeyClaim{Origin: MetonKeyOrigin{"test", "source", uuid.New(), uuid.New(), uuid.New(), uuid.New(), 1}, RemoteUser: 12,
		SourceMarker: uuid.New(), Session: uuid.New(), Family: uuid.New(), SecurityVersion: 1, IdentityRecoveryVersion: 1, Binding: uuid.New(), Generation: 1, Operation: uuid.New(), Dispatch: uuid.New()}
	req := MetonRetireRequest{1, c, uuid.New(), 21, now.Add(20 * time.Second)}
	if !source.CanRetire(&req, c.Operation, now) || source.CanRetire(&req, uuid.New(), now) || source.CanRetire(&req, c.Operation, now.Add(time.Minute)) {
		t.Fatal("original operation or deadline not enforced")
	}
}
