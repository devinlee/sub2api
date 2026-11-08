package service

import (
	"context"
	"errors"
	"os"
	"regexp"
	"strings"

	"github.com/google/uuid"
)

// MetonRegistrationGrant 冻结原创建、原受益人、资格及换算快照。业务码只由资格派生。
type MetonRegistrationGrant struct {
	MetonManagedClaim
	RemoteUser   int64     `json:"remoteUser"`
	SourceMarker uuid.UUID `json:"sourceMarker"`
	Eligibility  uuid.UUID `json:"eligibility"`
	Rule         string    `json:"rule"`
	Unit         string    `json:"unit"`
	Amount       string    `json:"amount"`
}
type MetonGrantReceipt struct {
	MetonRegistrationGrant
	BusinessCode string    `json:"businessCode"`
	Event        uuid.UUID `json:"event"`
	NativeCodeID int64     `json:"nativeCodeId"`
	State        string    `json:"state"`
}
type MetonGrantStore interface {
	RegistrationGrant(context.Context, MetonManagedSource, uuid.UUID, uuid.UUID, *MetonRegistrationGrant) (*MetonGrantReceipt, error)
}

var grantAmount = regexp.MustCompile("^(0|[1-9][0-9]{0,11})[.][0-9]{8}$")
var ErrMetonGrantConflict = errors.New("original grant requires reconciliation")

// GrantKeyID 只认专用托管模式及互斥的发放／查原凭证密钥，已有注销、账号或会话权限不能继承。
func (s MetonManagedSource) GrantKeyID(write bool) (string, bool) {
	w, r := os.Getenv("METON_MANAGED_GRANT_WRITE_KEY_ID"), os.Getenv("METON_MANAGED_GRANT_READ_KEY_ID")
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || !metonKeyID.MatchString(w) || !metonKeyID.MatchString(r) || w == r {
		return "", false
	}
	for _, other := range []string{s.CreateKeyID, s.ReadKeyID, os.Getenv("METON_MANAGED_FUNDS_READ_KEY_ID"), os.Getenv("METON_MANAGED_ISSUE_KEY_ID"),
		os.Getenv("METON_MANAGED_INSPECT_KEY_ID"), os.Getenv("METON_MANAGED_ROTATE_KEY_ID"), os.Getenv("METON_MANAGED_CLOSE_KEY_ID")} {
		if other == w || other == r {
			return "", false
		}
	}
	if write {
		return w, true
	}
	return r, true
}

func (s MetonManagedSource) ValidRegistrationGrant(q *MetonRegistrationGrant, creation, grant uuid.UUID) bool {
	return q != nil && s.ValidClaim(&q.MetonManagedClaim) && q.Operation == creation && q.Eligibility == grant && grant != uuid.Nil &&
		q.RemoteUser > 0 && q.SourceMarker != uuid.Nil && metonName.MatchString(q.Rule) && metonName.MatchString(q.Unit) &&
		grantAmount.MatchString(q.Amount) && q.Amount != "0.00000000"
}

// RegistrationGrant 缺仓储、代次变化或回执不符都保留未知。绝不调用原生余额兑换作为后备。
func (s *adminServiceImpl) RegistrationGrant(ctx context.Context, origin MetonManagedSource, creation, grant uuid.UUID, q *MetonRegistrationGrant) (*MetonGrantReceipt, error) {
	live, ok := MetonSource()
	_, enabled := origin.GrantKeyID(q != nil)
	repo, available := s.userRepo.(MetonGrantStore)
	if !ok || !enabled || live != origin || !available || creation == uuid.Nil || grant == uuid.Nil || q != nil && !origin.ValidRegistrationGrant(q, creation, grant) {
		return nil, ErrMetonClosed
	}
	result, err := repo.RegistrationGrant(ctx, origin, creation, grant, q)
	if err != nil || result == nil {
		return nil, err
	}
	if !origin.ValidRegistrationGrant(&result.MetonRegistrationGrant, creation, grant) || result.State != "redeemed" || result.Event == uuid.Nil ||
		result.NativeCodeID <= 0 || result.BusinessCode != strings.ReplaceAll(grant.String(), "-", "") || q != nil && result.MetonRegistrationGrant != *q {
		return nil, ErrMetonClosed
	}
	return result, nil
}
