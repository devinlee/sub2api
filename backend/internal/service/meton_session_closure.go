package service

import (
	"context"
	"os"
	"time"

	"github.com/google/uuid"
)

type MetonSessionClaim struct {
	Origin       MetonKeyOrigin `json:"origin"`
	RemoteUser   int64          `json:"remoteUser"`
	SourceMarker uuid.UUID      `json:"sourceMarker"`
	Session      uuid.UUID      `json:"session"`
	Operation    uuid.UUID      `json:"operation"`
}
type MetonSessionCloseRequest struct {
	Version     int               `json:"version"`
	Claim       MetonSessionClaim `json:"claim"`
	PermitUntil time.Time         `json:"permitUntil"`
}
type MetonClosedSession struct {
	Version       int                `json:"version"`
	State         string             `json:"state"`
	Claim         MetonSessionClaim  `json:"claim"`
	ClosureMarker uuid.UUID          `json:"closureMarker"`
	ClosedAt      time.Time          `json:"closedAt"`
	Target        *MetonClosedTarget `json:"target,omitempty"`
}
type MetonClosedTarget struct {
	Binding   uuid.UUID      `json:"binding"`
	State     string         `json:"state"`
	KeyMarker *uuid.UUID     `json:"keyMarker,omitempty"`
	RemoteKey *int64         `json:"remoteKey,omitempty"`
	KeyClaim  *MetonKeyClaim `json:"keyClaim,omitempty"`
}
type MetonSessionClosureStore interface {
	ManagedSessionClosure(context.Context, MetonKeySource, uuid.UUID, *MetonSessionCloseRequest, *uuid.UUID) (*MetonClosedSession, error)
}

func (s MetonKeySource) CloseID() (string, bool) {
	id := os.Getenv("METON_MANAGED_CLOSE_KEY_ID")
	rot, ok := s.RotationID()
	return id, ok && metonKeyID.MatchString(id) && id != rot && id != s.CreateKeyID && id != s.ReadKeyID && id != s.IssueID && id != s.InspectID
}
func (s MetonKeySource) ValidSession(c MetonSessionClaim) bool {
	o := c.Origin
	return s.ValidClaim(&MetonManagedClaim{Version: 1, Environment: o.Environment, Source: o.Source, User: o.User, Account: o.Account, Operation: o.Operation, Dispatch: o.Dispatch, Epoch: o.Epoch}) &&
		c.RemoteUser > 0 && c.SourceMarker != uuid.Nil && c.Session != uuid.Nil && c.Operation != uuid.Nil
}
func (s MetonKeySource) CanClose(req *MetonSessionCloseRequest, op uuid.UUID, now time.Time) bool {
	return req != nil && req.Version == 1 && s.ValidSession(req.Claim) && req.Claim.Operation == op && req.PermitUntil.After(now) && !req.PermitUntil.After(now.Add(30*time.Second))
}

// 查无不证明没有签发。只有带原关闭标识的逐项回执可以说明一个绑定最终未派发或已停用。
func (s MetonKeySource) ValidClosureReply(op uuid.UUID, req *MetonSessionCloseRequest, target *uuid.UUID, r *MetonClosedSession) bool {
	if r == nil || r.Version != 1 || r.State != "closed" || !s.ValidSession(r.Claim) || r.Claim.Operation != op || req != nil && r.Claim != req.Claim ||
		r.ClosureMarker == uuid.Nil || r.ClosedAt.Unix() < 0 || r.ClosedAt.After(time.Now().Add(5*time.Second)) {
		return false
	}
	if target == nil {
		return r.Target == nil
	}
	t := r.Target
	if t == nil || *target == uuid.Nil || t.Binding != *target {
		return false
	}
	if t.State == "never_issued" {
		return t.RemoteKey == nil && t.KeyMarker == nil && t.KeyClaim == nil
	}
	k := t.KeyClaim
	return t.State == "retired" && t.RemoteKey != nil && *t.RemoteKey > 0 && t.KeyMarker != nil && *t.KeyMarker != uuid.Nil &&
		k != nil && s.Valid(*k) && k.Origin == r.Claim.Origin && k.SourceMarker == r.Claim.SourceMarker && k.RemoteUser == r.Claim.RemoteUser && k.Session == r.Claim.Session && k.Binding == t.Binding
}
func (s *adminServiceImpl) ManagedSessionClosure(ctx context.Context, source MetonKeySource, op uuid.UUID, req *MetonSessionCloseRequest, target *uuid.UUID) (*MetonClosedSession, error) {
	current, ok := CurrentMetonKeySource()
	if !ok || current != source || op == uuid.Nil || target != nil && *target == uuid.Nil || req != nil && (target != nil || !source.CanClose(req, op, time.Now())) {
		return nil, ErrMetonClosed
	}
	if _, ok := source.CloseID(); !ok {
		return nil, ErrMetonClosed
	}
	repo, ok := s.userRepo.(MetonSessionClosureStore)
	if !ok {
		return nil, ErrMetonClosed
	}
	return repo.ManagedSessionClosure(ctx, source, op, req, target)
}
