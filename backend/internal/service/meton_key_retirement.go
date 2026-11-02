package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"github.com/google/uuid"
	"os"
	"time"
)

type MetonRetireRequest struct {
	Version     int           `json:"version"`
	Claim       MetonKeyClaim `json:"claim"`
	KeyMarker   uuid.UUID     `json:"keyMarker"`
	RemoteKey   int64         `json:"remoteKey"`
	PermitUntil time.Time     `json:"permitUntil"`
}
type MetonRetiredKey struct {
	Version   int           `json:"version"`
	State     string        `json:"state"`
	Claim     MetonKeyClaim `json:"claim"`
	KeyMarker uuid.UUID     `json:"keyMarker"`
	RemoteKey int64         `json:"remoteKey"`
	RetiredAt time.Time     `json:"retiredAt"`
}
type MetonRetireStore interface {
	ManagedRetirement(context.Context, MetonKeySource, uuid.UUID, *MetonRetireRequest) (*MetonRetiredKey, error)
}
type ManagedAdmissionReader interface {
	CurrentManagedKey(context.Context, MetonKeySource, int64, int64, string) (bool, error)
}

func (s MetonKeySource) RotationID() (string, bool) {
	id := os.Getenv("METON_MANAGED_ROTATE_KEY_ID")
	return id, metonKeyID.MatchString(id) && id != s.CreateKeyID && id != s.ReadKeyID && id != s.IssueID && id != s.InspectID
}
func (s MetonKeySource) CanRetire(v *MetonRetireRequest, op uuid.UUID, now time.Time) bool {
	return v != nil && s.Valid(v.Claim) && v.Claim.Operation == op && v.Version == 1 && v.KeyMarker != uuid.Nil && v.RemoteKey > 0 &&
		v.PermitUntil.After(now) && !v.PermitUntil.After(now.Add(30*time.Second))
}
func (s *adminServiceImpl) ManagedRetirement(ctx context.Context, source MetonKeySource, op uuid.UUID, req *MetonRetireRequest) (*MetonRetiredKey, error) {
	current, ok := CurrentMetonKeySource()
	if !ok || current != source || op == uuid.Nil || req != nil && !source.CanRetire(req, op, time.Now()) {
		return nil, ErrMetonClosed
	}
	repo, ok := s.userRepo.(MetonRetireStore)
	if !ok {
		return nil, ErrMetonClosed
	}
	return repo.ManagedRetirement(ctx, source, op, req)
}

// 专用版本绕过整套原生 Key 缓存，重新读取原用户、凭据及关停栅栏；读取失败不能回落到 L1/Redis 的旧授权。
func (s *APIKeyService) readCurrentManagedKey(ctx context.Context, key string) (*APIKey, error) {
	source, ok := CurrentMetonKeySource()
	port, supported := s.apiKeyRepo.(ManagedAdmissionReader)
	if !ok || !supported {
		return nil, ErrAPIKeyNotFound
	}
	actual, err := s.lookupAPIKeyForAuth(ctx, key)
	if err != nil || actual == nil || actual.ID <= 0 || actual.UserID <= 0 {
		return nil, ErrAPIKeyNotFound
	}
	digest := sha256.Sum256([]byte(key))
	admitted, err := port.CurrentManagedKey(ctx, source, actual.ID, actual.UserID, hex.EncodeToString(digest[:]))
	if err != nil || !admitted {
		return nil, ErrAPIKeyNotFound
	}
	actual.Key = key
	s.compileAPIKeyIPRules(actual)
	return actual, nil
}
