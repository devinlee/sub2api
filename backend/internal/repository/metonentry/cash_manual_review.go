//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

/** 服务身份只取得人员接缝；原加密材料由已有实现产生，不另建退款或争议业务状态。 */
type cashManualReviewStore struct {
	materials *refundPayerReviewStore
	route     json.RawMessage
}

/** 原上下文可能刷新迟到现金导致的争议版本，因此始终使用可提交的受限事务。 */
func (s *cashManualReviewStore) context(ctx context.Context, key string) (json.RawMessage, error) {
	tx, err := s.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var raw []byte
	if err = tx.QueryRowContext(ctx, "SELECT meton_inbox.cash_manual_review_context($1,$2)", string(s.route), key).Scan(&raw); err != nil {
		return nil, err
	}
	if !s.matchesScope(raw) {
		return nil, service.ErrMetonClosed
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return raw, nil
}

/** 只执行一次原命令；查询模式不读取密钥或材料，不把查无当作可以再次批准。 */
func (s *cashManualReviewStore) record(ctx context.Context, q service.CashManualReviewCommand, material []byte, resultOnly bool) (json.RawMessage, error) {
	if !q.Valid() || resultOnly && len(material) != 0 {
		return nil, service.ErrMetonClosed
	}
	tx, err := s.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	command, err := json.Marshal(q)
	if err != nil {
		return nil, err
	}
	action := "result"
	var sealed []byte
	var keyRef any
	if !resultOnly {
		action = "record"
		var current []byte
		if err = tx.QueryRowContext(ctx, "SELECT meton_inbox.cash_manual_review_context($1,$2)", string(s.route), q.OriginalKey).Scan(&current); err != nil {
			return nil, err
		}
		var v struct {
			State       string
			BasisDigest string
			Value       struct{ App string }
		}
		if !s.matchesScope(current) || json.Unmarshal(current, &v) != nil {
			return nil, service.ErrMetonClosed
		}
		if v.State == "observed" && v.BasisDigest == q.BasisDigest {
			kind := payerReview
			if q.ReviewKind == "alternative" {
				kind = alternativeReview
			} else if q.ReviewKind == "dispute" {
				kind = cashDisputeReview
			}
			// AAD 路由由数据库规范化，原样留在人员回执中；以后解封不猜测 JSON 字段顺序。
			var fullRoute string
			if v.Value.App == "" {
				return nil, service.ErrMetonClosed
			}
			if err = tx.QueryRowContext(ctx, "SELECT ($1::jsonb || jsonb_build_object('app',$2::text))::text", string(s.route), v.Value.App).Scan(&fullRoute); err != nil {
				return nil, err
			}
			ref, _ := uuid.Parse(strings.Split(q.OriginalKey, "/")[1])
			_, sealed, _, err = s.materials.sealMaterial(ctx, tx, ref, q.Operation, q.Facts, material, kind, json.RawMessage(fullRoute))
			if err != nil {
				return nil, err
			}
			keyRef = s.materials.keyRef
		}
	}
	var raw []byte
	if err = tx.QueryRowContext(ctx, "SELECT meton_inbox.cash_manual_review($1,$2,$3,$4,$5)", string(s.route), string(command), keyRef, sealed, action).Scan(&raw); err != nil {
		return nil, err
	}
	if !s.matchesScope(raw) || !q.Until.After(time.Now()) {
		return nil, service.ErrMetonClosed
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return raw, nil
}

/** 只由显式隔离组合方装配；没有池时拒绝，不改用来源或收件身份。 */
func (s *cashManualReviewStore) begin(ctx context.Context) (*sql.Tx, error) {
	if s == nil || s.materials == nil || s.materials.archive == nil {
		return nil, service.ErrMetonClosed
	}
	tx, err := s.materials.archive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		_ = tx.Rollback()
		return nil, err
	}
	return tx, nil
}

/** 原路由所有字段在提交前复验，不能把其他商户或恢复代次的结果返回给当前操作。 */
func (s *cashManualReviewStore) matchesScope(raw []byte) bool {
	var expected service.CashArchiveOriginalScope
	var result struct {
		Scope *service.CashArchiveOriginalScope
	}
	return len(raw) > 0 && len(raw) <= 32768 && metonexecution.DecodeStrict(s.route, &expected) == nil &&
		json.Unmarshal(raw, &result) == nil && result.Scope != nil && *result.Scope == expected
}
