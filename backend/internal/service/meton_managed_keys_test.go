package service

import (
	"github.com/google/uuid"
	"testing"
	"time"
)

func TestMetonManagedKeyPurposeFence(t *testing.T) {
	t.Setenv("METON_MANAGED_ENVIRONMENT", "test")
	t.Setenv("METON_MANAGED_SOURCE", "source")
	t.Setenv("METON_MANAGED_EPOCH", "3")
	t.Setenv("METON_MANAGED_CREATE_KEY_ID", "000000000000000000000001")
	t.Setenv("METON_MANAGED_READ_KEY_ID", "000000000000000000000002")
	t.Setenv("METON_MANAGED_ISSUE_KEY_ID", "000000000000000000000003")
	t.Setenv("METON_MANAGED_INSPECT_KEY_ID", "000000000000000000000004")
	source, ok := CurrentMetonKeySource()
	if !ok {
		t.Fatal("valid fixture closed")
	}
	now := time.Now()
	c := MetonKeyClaim{Origin: MetonKeyOrigin{"test", "source", uuid.New(), uuid.New(), uuid.New(), uuid.New(), 3},
		RemoteUser: 11, SourceMarker: uuid.New(), Session: uuid.New(), Family: uuid.New(), SecurityVersion: 2, IdentityRecoveryVersion: 1,
		Binding: uuid.New(), Generation: 2, Operation: uuid.New(), Dispatch: uuid.New()}
	req := MetonKeyRequest{Version: 1, Purpose: "model", Claim: c, PermitUntil: now.Add(20 * time.Second)}
	if !source.CanIssue(&req, now) {
		t.Fatal("valid permit rejected")
	}
	reply := MetonKeyReply{Version: 1, Purpose: "model", State: "issued", Claim: c, KeyMarker: uuid.New(), RemoteKey: 9, CreatedAt: now,
		ExpiresAt: now.Add(24 * time.Hour), MaterialSha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	t.Run("original_read", func(t *testing.T) {
		if !source.AllowsReply(c.Operation, nil, &reply) {
			t.Fatal("original metadata rejected")
		}
	})
	t.Run("other_session_cannot_receive_material", func(t *testing.T) {
		wrong := reply
		wrong.Claim.Session = uuid.New()
		if source.AllowsReply(c.Operation, &req, &wrong) {
			t.Fatal("foreign source object delivered")
		}
	})
	t.Run("read_cannot_deliver_secret", func(t *testing.T) {
		wrong := reply
		wrong.Secret = "synthetic-non-key"
		if source.AllowsReply(c.Operation, nil, &wrong) || source.AllowsReply(c.Operation, &req, &wrong) {
			t.Fatal("invalid material delivered")
		}
	})
	for _, tc := range []struct {
		name  string
		alter func(*MetonKeyRequest)
	}{
		{"expired", func(r *MetonKeyRequest) { r.PermitUntil = now }},
		{"too_long", func(r *MetonKeyRequest) { r.PermitUntil = now.Add(time.Minute) }},
		{"account_token", func(r *MetonKeyRequest) { r.Purpose = "account" }},
		{"wrong_source", func(r *MetonKeyRequest) { r.Claim.Origin.Source = "wrong" }},
		{"old_epoch", func(r *MetonKeyRequest) { r.Claim.Origin.Epoch-- }},
		{"missing_owner", func(r *MetonKeyRequest) { r.Claim.SourceMarker = uuid.Nil }},
		{"missing_session", func(r *MetonKeyRequest) { r.Claim.Session = uuid.Nil }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v := req
			tc.alter(&v)
			if source.CanIssue(&v, now) {
				t.Fatal("invalid permit accepted")
			}
		})
	}
	t.Setenv("METON_MANAGED_INSPECT_KEY_ID", source.IssueID)
	if _, ok := CurrentMetonKeySource(); ok {
		t.Fatal("same key acquired two purposes")
	}
}
