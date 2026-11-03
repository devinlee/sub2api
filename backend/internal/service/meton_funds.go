package service

import (
	"context"
	"os"
	"time"

	"github.com/google/uuid"
)

// MetonFundsReceipt 只描述受控时点的资金预查。它不代表已退款、已注销或可以发放额度。
type MetonFundsReceipt struct {
	Version      int               `json:"version"`
	Origin       MetonManagedClaim `json:"origin"`
	RemoteUser   int64             `json:"remoteUser"`
	SourceMarker uuid.UUID         `json:"sourceMarker"`
	BirthMarker  *uuid.UUID        `json:"birthMarker,omitempty"`
	State        string            `json:"state"`
	CheckedAt    time.Time         `json:"checkedAt"`
	ValidUntil   time.Time         `json:"validUntil"`
}
type MetonFundsStore interface {
	ManagedFunds(context.Context, MetonManagedSource, uuid.UUID) (*MetonFundsReceipt, error)
}

// FundsID 与写入、建号查询和会话权限互斥。其他构建和以后开放资金的环境不签 S1 证明。
func (s MetonManagedSource) FundsID() (string, bool) {
	id := os.Getenv("METON_MANAGED_FUNDS_READ_KEY_ID")
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s1-closed-v1" || !metonKeyID.MatchString(id) || id == s.CreateKeyID || id == s.ReadKeyID {
		return "", false
	}
	for _, env := range []string{"METON_MANAGED_ISSUE_KEY_ID", "METON_MANAGED_INSPECT_KEY_ID", "METON_MANAGED_ROTATE_KEY_ID", "METON_MANAGED_CLOSE_KEY_ID"} {
		if id == os.Getenv(env) {
			return "", false
		}
	}
	return id, true
}
func (s MetonManagedSource) ValidFunds(op uuid.UUID, r *MetonFundsReceipt, now time.Time) bool {
	return r != nil && r.Version == 1 && s.ValidClaim(&r.Origin) && r.Origin.Operation == op && r.RemoteUser > 0 && r.SourceMarker != uuid.Nil &&
		(r.BirthMarker == nil || *r.BirthMarker != uuid.Nil) && (r.State == "history_unverified" || r.State == "funds_or_activity" || r.State == "controlled_empty" && r.BirthMarker != nil) &&
		!r.CheckedAt.IsZero() && !r.CheckedAt.After(now.Add(time.Second)) && r.ValidUntil.Equal(r.CheckedAt.Add(5*time.Second)) && r.ValidUntil.After(now)
}
func (s *adminServiceImpl) ManagedFunds(ctx context.Context, source MetonManagedSource, op uuid.UUID) (*MetonFundsReceipt, error) {
	live, available := MetonSource()
	_, readable := source.FundsID()
	repo, ok := s.userRepo.(MetonFundsStore)
	if !available || !readable || live != source || !ok || op == uuid.Nil {
		return nil, ErrMetonClosed
	}
	result, err := repo.ManagedFunds(ctx, source, op)
	if err != nil || result != nil && !source.ValidFunds(op, result, time.Now()) {
		return nil, ErrMetonClosed
	}
	return result, nil
}
