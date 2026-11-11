package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

/** 材料只在首次记录请求中提交；原回执查询使用相同意图，不重新发送材料。 */
type CashManualReviewRequest struct {
	Version     int                     `json:"version"`
	Environment string                  `json:"environment"`
	Source      string                  `json:"source"`
	Epoch       int64                   `json:"epoch"`
	ScopeKey    string                  `json:"scopeKey"`
	Command     CashManualReviewCommand `json:"command"`
	Material    []byte                  `json:"material,omitempty"`
}
type CashManualReviewStore interface {
	ReadCashManualReview(context.Context, string) (json.RawMessage, error)
	RecordCashManualReview(context.Context, CashManualReviewCommand, []byte, bool) (json.RawMessage, error)
}

/** 人工审核身份独立于读取、会员、重试和资金执行身份。 */
func (s MetonManagedSource) CashManualReviewKeyID() (string, bool) {
	return independentCashReadKey("METON_MANAGED_CASH_REVIEW_KEY_ID")
}
func ReadCashManualReviewRequest(raw []byte, q *CashManualReviewRequest) error {
	return decodeStatement(raw, q)
}

/** 原案的完整规范键不接受另一个类别、应用或账号参数。 */
func cashManualKey(key string) bool {
	p := strings.Split(key, "/")
	if len(p) != 2 || (p[0] != "refund" && p[0] != "dispute") {
		return false
	}
	id, e := uuid.Parse(p[1])
	return e == nil && id != uuid.Nil && id.String() == p[1]
}
func (s MetonManagedSource) ValidCashManualContext(q CashArchiveRequest) bool {
	return s.ValidCashArchive(q) && q.OriginalKey != nil && cashManualKey(*q.OriginalKey) && q.After == nil && q.Size == 1
}
func (s MetonManagedSource) ValidCashManualReview(q CashManualReviewRequest, resultOnly bool) bool {
	if q.Version != 1 || q.Environment != s.Environment || q.Source != s.Source || q.Epoch != s.Epoch || !cashStatementDigest.MatchString(q.ScopeKey) || !q.Command.Valid() {
		return false
	}
	if resultOnly {
		return len(q.Material) == 0
	}
	if len(q.Material) == 0 || len(q.Material) > 512*1024 {
		return false
	}
	var fields struct{ MaterialHash string }
	hash := sha256.Sum256(q.Material)
	return json.Unmarshal(q.Command.Facts, &fields) == nil && fields.MaterialHash == hex.EncodeToString(hash[:])
}

type cashManualContext struct {
	Format              int                      `json:"format"`
	State               string                   `json:"state"`
	Scope               CashArchiveOriginalScope `json:"scope"`
	OriginalKey         string                   `json:"originalKey"`
	BasisDigest         *string                  `json:"basisDigest"`
	Value               json.RawMessage          `json:"value"`
	FinancialAuthority  *bool                    `json:"financialAuthority"`
	ExecutionAuthorized *bool                    `json:"executionAuthorized"`
}
type cashManualReceipt struct {
	Format              int                      `json:"format"`
	State               string                   `json:"state"`
	Scope               CashArchiveOriginalScope `json:"scope"`
	Operation           uuid.UUID                `json:"operation"`
	OriginalKey         string                   `json:"originalKey"`
	BasisDigest         string                   `json:"basisDigest"`
	ReviewKind          string                   `json:"reviewKind"`
	FinancialAuthority  *bool                    `json:"financialAuthority"`
	ExecutionAuthorized *bool                    `json:"executionAuthorized"`
}

/** 同一归档服务的独立名额与期限；当前来源或审核密钥退役后，不交出迟到结果。 */
func (s *MetonCashArchive) manualReviewCall(ctx context.Context, source MetonManagedSource, scope string, call func(context.Context, CashManualReviewStore) (json.RawMessage, error)) (json.RawMessage, error) {
	live, ok := MetonSource()
	key, enabled := source.CashManualReviewKeyID()
	if s == nil || !ok || live != source || !enabled || scope != s.identity.ScopeKey || source.Environment != s.identity.Environment || source.Source != s.identity.Source || source.Epoch != s.identity.Epoch {
		return nil, ErrMetonClosed
	}
	store, ok := s.store.(CashManualReviewStore)
	if !ok {
		return nil, ErrMetonClosed
	}
	select {
	case s.budget <- struct{}{}:
		defer func() { <-s.budget }()
	default:
		return nil, ErrMetonClosed
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	raw, err := call(ctx, store)
	if err != nil || len(raw) == 0 || len(raw) > 32768 {
		return nil, ErrMetonClosed
	}
	live, ok = MetonSource()
	current, enabled := source.CashManualReviewKeyID()
	if !ok || live != source || !enabled || current != key || ctx.Err() != nil {
		return nil, ErrMetonClosed
	}
	return raw, nil
}

/** 只交出审核所需的原依据；密文、服务路由和人员材料不会进入公开响应。 */
func (s *MetonCashArchive) ReadManualReview(ctx context.Context, source MetonManagedSource, q CashArchiveRequest) (json.RawMessage, error) {
	if !source.ValidCashManualContext(q) {
		return nil, ErrMetonClosed
	}
	raw, err := s.manualReviewCall(ctx, source, q.ScopeKey, func(ctx context.Context, store CashManualReviewStore) (json.RawMessage, error) {
		return store.ReadCashManualReview(ctx, *q.OriginalKey)
	})
	if err != nil {
		return nil, err
	}
	var v cashManualContext
	if decodeStatement(raw, &v) != nil || v.Format != 1 || !manualScopeMatches(v.Scope, s.identity) || v.OriginalKey != *q.OriginalKey ||
		v.FinancialAuthority == nil || *v.FinancialAuthority || v.ExecutionAuthorized == nil || *v.ExecutionAuthorized {
		return nil, ErrMetonClosed
	}
	if v.State == "observed" {
		if v.BasisDigest == nil || !cashStatementDigest.MatchString(*v.BasisDigest) || !validManualValue(v.Value, v.OriginalKey) {
			return nil, ErrMetonClosed
		}
	} else if (v.State != "original_unavailable" && v.State != "original_pending") || v.BasisDigest != nil || string(v.Value) != "null" {
		return nil, ErrMetonClosed
	}
	return json.Marshal(struct {
		CashArchiveIdentity
		Format              int             `json:"format"`
		State               string          `json:"state"`
		OriginalKey         string          `json:"originalKey"`
		BasisDigest         *string         `json:"basisDigest"`
		Value               json.RawMessage `json:"value"`
		ObservedAt          time.Time       `json:"observedAt"`
		FinancialAuthority  bool            `json:"financialAuthority"`
		ExecutionAuthorized bool            `json:"executionAuthorized"`
	}{s.identity, 1, v.State, v.OriginalKey, v.BasisDigest, v.Value, time.Now().UTC(), false, false})
}

/** 原记录和结果查询分别调用，不因失败、未知或查无自动转成再次批准。 */
func (s *MetonCashArchive) RecordManualReview(ctx context.Context, source MetonManagedSource, q CashManualReviewRequest, resultOnly bool) (json.RawMessage, error) {
	if !source.ValidCashManualReview(q, resultOnly) {
		return nil, ErrMetonClosed
	}
	raw, err := s.manualReviewCall(ctx, source, q.ScopeKey, func(ctx context.Context, store CashManualReviewStore) (json.RawMessage, error) {
		return store.RecordCashManualReview(ctx, q.Command, q.Material, resultOnly)
	})
	if err != nil {
		return nil, err
	}
	var v cashManualReceipt
	if decodeStatement(raw, &v) != nil || v.Format != 1 || !manualScopeMatches(v.Scope, s.identity) || v.Operation != q.Command.Operation || v.OriginalKey != q.Command.OriginalKey ||
		v.BasisDigest != q.Command.BasisDigest || v.ReviewKind != q.Command.ReviewKind || !q.Command.Until.After(time.Now()) ||
		v.FinancialAuthority == nil || *v.FinancialAuthority || v.ExecutionAuthorized == nil || *v.ExecutionAuthorized {
		return nil, ErrMetonClosed
	}
	switch v.State {
	case "recorded", "operation_unknown", "original_unavailable", "original_pending", "basis_changed", "original_operation_exists":
	default:
		return nil, ErrMetonClosed
	}
	return json.Marshal(struct {
		CashArchiveIdentity
		Format              int       `json:"format"`
		State               string    `json:"state"`
		Operation           uuid.UUID `json:"operation"`
		OriginalKey         string    `json:"originalKey"`
		BasisDigest         string    `json:"basisDigest"`
		ReviewKind          string    `json:"reviewKind"`
		FinancialAuthority  bool      `json:"financialAuthority"`
		ExecutionAuthorized bool      `json:"executionAuthorized"`
	}{s.identity, 1, v.State, v.Operation, v.OriginalKey, v.BasisDigest, v.ReviewKind, false, false})
}

func manualScopeMatches(v CashArchiveOriginalScope, id CashArchiveIdentity) bool {
	return v.Deployment == id.Environment && v.Source == id.Source && v.Epoch == id.Epoch && v.KeyRef == id.KeyRef && v.InboxSystem == id.ArchiveSystem &&
		closureSystem.MatchString(v.SourceSystem) && v.SourceSystem != v.InboxSystem && v.Channel == "wechatpay" &&
		(v.CashEnvironment == "isolated" || v.CashEnvironment == "live") && len(v.Merchant) > 0 && len(v.Merchant) <= 32
}
