package service

import (
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestMetonManagedOriginalSessionClosure(t *testing.T) {
	t.Setenv("METON_MANAGED_ENVIRONMENT", "test")
	t.Setenv("METON_MANAGED_SOURCE", "source")
	t.Setenv("METON_MANAGED_EPOCH", "2")
	for i, name := range []string{"CREATE", "READ", "ISSUE", "INSPECT", "ROTATE", "CLOSE"} {
		t.Setenv("METON_MANAGED_"+name+"_KEY_ID", fmt.Sprintf("%024x", i+1))
	}
	s, ok := CurrentMetonKeySource()
	if !ok {
		t.Fatal("source unavailable")
	}
	o := MetonKeyOrigin{"test", "source", uuid.New(), uuid.New(), uuid.New(), uuid.New(), 2}
	c := MetonSessionClaim{o, 13, uuid.New(), uuid.New(), uuid.New()}
	now := time.Now()
	request := &MetonSessionCloseRequest{1, c, now.Add(20 * time.Second)}
	reply := MetonClosedSession{Version: 1, State: "closed", Claim: c, ClosureMarker: uuid.New(), ClosedAt: now}
	t.Run("separate_authority", func(t *testing.T) {
		if _, ok := s.CloseID(); !ok {
			t.Fatal("distinct close identity refused")
		}
		t.Setenv("METON_MANAGED_CLOSE_KEY_ID", s.InspectID)
		if _, ok := s.CloseID(); ok {
			t.Fatal("read identity gained writes")
		}
	})
	t.Run("original_deadline", func(t *testing.T) {
		if !s.CanClose(request, c.Operation, now) || s.CanClose(request, uuid.New(), now) || s.CanClose(request, c.Operation, now.Add(time.Minute)) {
			t.Fatal("original or deadline mismatch")
		}
	})
	t.Run("original_session", func(t *testing.T) {
		if !s.ValidClosureReply(c.Operation, request, nil, &reply) {
			t.Fatal("valid closure refused")
		}
		conflict := reply
		conflict.Claim.Session = uuid.New()
		if s.ValidClosureReply(c.Operation, request, nil, &conflict) {
			t.Fatal("wrong session accepted")
		}
	})
	t.Run("target_proof", func(t *testing.T) {
		target := uuid.New()
		v := reply
		v.Target = &MetonClosedTarget{Binding: target, State: "never_issued"}
		if !s.ValidClosureReply(c.Operation, nil, &target, &v) {
			t.Fatal("fenced absence refused")
		}
		k := int64(23)
		v.Target.RemoteKey = &k
		if s.ValidClosureReply(c.Operation, nil, &target, &v) {
			t.Fatal("ambiguous absence accepted")
		}
		m := uuid.New()
		v.Target.KeyMarker = &m
		v.Target.State = "retired"
		v.Target.KeyClaim = &MetonKeyClaim{Origin: c.Origin, RemoteUser: c.RemoteUser, SourceMarker: c.SourceMarker, Session: c.Session, Family: uuid.New(), SecurityVersion: 1, IdentityRecoveryVersion: 1, Binding: target, Generation: 1, Operation: target, Dispatch: uuid.New()}
		if !s.ValidClosureReply(c.Operation, nil, &target, &v) {
			t.Fatal("retired original refused")
		}
		other := uuid.New()
		if s.ValidClosureReply(c.Operation, nil, &other, &v) {
			t.Fatal("another binding accepted")
		}
		v.Target.KeyClaim.Session = uuid.New()
		if s.ValidClosureReply(c.Operation, nil, &target, &v) {
			t.Fatal("foreign original key claim accepted")
		}
	})
	t.Run("no_native_web_grant", func(t *testing.T) {
		// 在读取签名设施之前拒绝普通用户。管理员通路仍用原生框架并由隔离实例单独联验。
		if _, err := (&AuthService{}).generateAccessToken(&User{ID: 21, Role: "user"}, "old", ""); err != ErrInvalidCredentials {
			t.Fatal("ordinary native web token issued")
		}
	})
}
