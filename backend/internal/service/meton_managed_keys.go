package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"github.com/google/uuid"
	"os"
	"time"
)

type MetonKeyOrigin struct {
	Environment string    `json:"environment"`
	Source      string    `json:"source"`
	User        uuid.UUID `json:"user"`
	Account     uuid.UUID `json:"account"`
	Operation   uuid.UUID `json:"operation"`
	Dispatch    uuid.UUID `json:"dispatch"`
	Epoch       int64     `json:"epoch"`
}
type MetonKeyClaim struct {
	Origin                  MetonKeyOrigin `json:"origin"`
	RemoteUser              int64          `json:"remoteUser"`
	SourceMarker            uuid.UUID      `json:"sourceMarker"`
	Session                 uuid.UUID      `json:"session"`
	Family                  uuid.UUID      `json:"family"`
	SecurityVersion         int64          `json:"securityVersion"`
	IdentityRecoveryVersion int64          `json:"identityRecoveryVersion"`
	Binding                 uuid.UUID      `json:"binding"`
	Generation              int64          `json:"generation"`
	Operation               uuid.UUID      `json:"operation"`
	Dispatch                uuid.UUID      `json:"dispatch"`
}
type MetonKeyRequest struct {
	Version     int           `json:"version"`
	Purpose     string        `json:"purpose"`
	Claim       MetonKeyClaim `json:"claim"`
	PermitUntil time.Time     `json:"permitUntil"`
}
type MetonKeyReply struct {
	Version        int           `json:"version"`
	Purpose        string        `json:"purpose"`
	State          string        `json:"state"`
	Claim          MetonKeyClaim `json:"claim"`
	KeyMarker      uuid.UUID     `json:"keyMarker"`
	RemoteKey      int64         `json:"remoteKey"`
	CreatedAt      time.Time     `json:"createdAt"`
	ExpiresAt      time.Time     `json:"expiresAt"`
	MaterialSha256 string        `json:"materialSha256"`
	Secret         string        `json:"secret,omitempty"`
}
type MetonKeySource struct {
	MetonManagedSource
	IssueID, InspectID string
}
type MetonKeyStore interface {
	ManagedKey(context.Context, MetonKeySource, uuid.UUID, *MetonKeyRequest) (*MetonKeyReply, error)
}

// 即使存储端返回混淆的对象，也不能把另一个会话的材料送出管理边界。
func (s MetonKeySource) AllowsReply(op uuid.UUID, issue *MetonKeyRequest, reply *MetonKeyReply) bool {
	if reply == nil || reply.Version != 1 || reply.Purpose != "model" || reply.State != "issued" || !s.Valid(reply.Claim) || reply.Claim.Operation != op ||
		reply.KeyMarker == uuid.Nil || reply.RemoteKey <= 0 || reply.CreatedAt.Unix() < 0 || !reply.ExpiresAt.After(reply.CreatedAt) ||
		reply.ExpiresAt.Sub(reply.CreatedAt) > 24*time.Hour || len(reply.MaterialSha256) != 64 {
		return false
	}
	raw, err := hex.DecodeString(reply.MaterialSha256)
	if err != nil || hex.EncodeToString(raw) != reply.MaterialSha256 {
		return false
	}
	if issue == nil {
		return reply.Secret == ""
	}
	if issue.Claim != reply.Claim {
		return false
	}
	if reply.Secret == "" {
		return true
	}
	if len(reply.Secret) != 67 || reply.Secret[:3] != "sk-" {
		return false
	}
	hash := sha256.Sum256([]byte(reply.Secret))
	return hex.EncodeToString(hash[:]) == reply.MaterialSha256
}

// 账号创建、账号查询、Key 签发和 Key 只读核对分别绑定一个原生受限身份。
func CurrentMetonKeySource() (MetonKeySource, bool) {
	base, ok := MetonSource()
	source := MetonKeySource{base, os.Getenv("METON_MANAGED_ISSUE_KEY_ID"), os.Getenv("METON_MANAGED_INSPECT_KEY_ID")}
	ids := map[string]bool{source.CreateKeyID: true, source.ReadKeyID: true, source.IssueID: true, source.InspectID: true}
	return source, ok && len(ids) == 4 && metonKeyID.MatchString(source.IssueID) && metonKeyID.MatchString(source.InspectID)
}
func (s MetonKeySource) Valid(c MetonKeyClaim) bool {
	o := c.Origin
	return s.ValidClaim(&MetonManagedClaim{Version: 1, Environment: o.Environment, Source: o.Source, User: o.User, Account: o.Account, Operation: o.Operation, Dispatch: o.Dispatch, Epoch: o.Epoch}) &&
		c.RemoteUser > 0 && c.SourceMarker != uuid.Nil && c.Session != uuid.Nil && c.Family != uuid.Nil && c.SecurityVersion > 0 && c.IdentityRecoveryVersion > 0 &&
		c.Binding != uuid.Nil && c.Generation > 0 && c.Operation != uuid.Nil && c.Dispatch != uuid.Nil
}
func (s MetonKeySource) CanIssue(r *MetonKeyRequest, now time.Time) bool {
	return r != nil && r.Version == 1 && r.Purpose == "model" && s.Valid(r.Claim) && r.PermitUntil.After(now) && !r.PermitUntil.After(now.Add(30*time.Second))
}

// 原生业务服务在路由之后再次核对部署身份。读取不能通过请求体切换远端用户或获取材料。
func (s *adminServiceImpl) ManagedKey(ctx context.Context, source MetonKeySource, op uuid.UUID, issue *MetonKeyRequest) (*MetonKeyReply, error) {
	current, ok := CurrentMetonKeySource()
	if !ok || source != current || op == uuid.Nil || issue != nil && (issue.Claim.Operation != op || !source.CanIssue(issue, time.Now())) {
		return nil, ErrMetonClosed
	}
	repo, ok := s.userRepo.(MetonKeyStore)
	if !ok {
		return nil, ErrMetonClosed
	}
	return repo.ManagedKey(ctx, source, op, issue)
}
