//go:build meton_managed

package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
)

func TestMetonModelReadMissingRepositoryAndClosedMode(t *testing.T) {
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": "100000000000000000000001", "READ_KEY_ID": "100000000000000000000002", "MODEL_READ_KEY_ID": "100000000000000000000009"} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	s, ok := MetonSource()
	if !ok {
		t.Fatal("source unavailable")
	}
	if _, err := new(adminServiceImpl).OriginalModel(context.Background(), s, uuid.New(), "meton.chat.v1", uuid.New(), nil); !errors.Is(err, ErrMetonClosed) {
		t.Fatal("missing store fell back")
	}
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s1-closed-v1")
	if _, ok := s.ModelReadID(); ok {
		t.Fatal("query opened without source mode")
	}
}
