package service

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"os"
	"regexp"
	"strconv"
)

// MetonManagedClaim 是已登记来源的原创建，不接受邮箱、余额、密码、订阅或用户凭据。
type MetonManagedClaim struct {
	Version     int       `json:"version"`
	Environment string    `json:"environment"`
	Source      string    `json:"source"`
	User        uuid.UUID `json:"user"`
	Account     uuid.UUID `json:"account"`
	Operation   uuid.UUID `json:"operation"`
	Dispatch    uuid.UUID `json:"dispatch"`
	Epoch       int64     `json:"epoch"`
}
type MetonManagedReceipt struct {
	MetonManagedClaim
	State                string    `json:"state"`
	RemoteUser           int64     `json:"remoteUser"`
	SourceMarker         uuid.UUID `json:"sourceMarker"`
	InitialBalance       int64     `json:"initialBalance"`
	InitialSubscriptions int       `json:"initialSubscriptions"`
	RestrictPublicGroups bool      `json:"restrictPublicGroups"`
}
type MetonManagedSource struct {
	Environment, Source, CreateKeyID, ReadKeyID string
	Epoch                                       int64
}
type MetonManagedStore interface {
	ManagedAccount(context.Context, MetonManagedSource, uuid.UUID, *MetonManagedClaim) (*MetonManagedReceipt, error)
}

var metonName = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,120}$`)
var metonKeyID = regexp.MustCompile(`^[0-9a-f]{24}$`)
var ErrMetonClosed = errors.New("managed source unavailable")

// MetonSource 从部署配置读取来源及写代次，不根据客户端声明选择实例或改变账务策略。
func MetonSource() (MetonManagedSource, bool) {
	epoch, e := strconv.ParseInt(os.Getenv("METON_MANAGED_EPOCH"), 10, 64)
	s := MetonManagedSource{os.Getenv("METON_MANAGED_ENVIRONMENT"), os.Getenv("METON_MANAGED_SOURCE"), os.Getenv("METON_MANAGED_CREATE_KEY_ID"), os.Getenv("METON_MANAGED_READ_KEY_ID"), epoch}
	return s, MetonManagedBuild && e == nil && epoch > 0 && metonName.MatchString(s.Environment) && metonName.MatchString(s.Source) && metonKeyID.MatchString(s.CreateKeyID) && metonKeyID.MatchString(s.ReadKeyID) && s.CreateKeyID != s.ReadKeyID
}
func (s MetonManagedSource) ValidClaim(c *MetonManagedClaim) bool {
	return c != nil && c.Version == 1 && c.Environment == s.Environment && c.Source == s.Source && c.Epoch == s.Epoch && c.User != uuid.Nil && c.Account != uuid.Nil && c.Operation != uuid.Nil && c.Dispatch != uuid.Nil
}

// ManagedAccount 只沿现有用户仓储到达本实例，缺持久能力不能回退到原生管理建号。
func (s *adminServiceImpl) ManagedAccount(ctx context.Context, source MetonManagedSource, id uuid.UUID, c *MetonManagedClaim) (*MetonManagedReceipt, error) {
	live, ok := MetonSource()
	if !ok || live != source || id == uuid.Nil || c != nil && (!source.ValidClaim(c) || c.Operation != id) {
		return nil, ErrMetonClosed
	}
	repo, ok := s.userRepo.(MetonManagedStore)
	if !ok {
		return nil, ErrMetonClosed
	}
	return repo.ManagedAccount(ctx, source, id, c)
}
