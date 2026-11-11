//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

/** syncAftercare 共用原结清事务的现金锁；归档新事实先提交，下一轮才交给来源投影。 */
func (w *refundSettlementWorker) syncAftercare(ctx context.Context, tx *sql.Tx, ref uuid.UUID) (bool, error) {
	var origin json.RawMessage
	if err := cashSourceResult(ctx, w.source, &origin, "SELECT meton_ledger.prepare_original_refund_aftercare($1,$2)", w.route, ref); err != nil {
		return false, err
	}
	var head struct{ State string }
	if err := json.Unmarshal(origin, &head); err != nil {
		return false, err
	}
	if head.State != "ready" && head.State != "not_opened" {
		return false, nil
	}
	// 来源回退可能丢失原申请。只读回独立库已有事实，不用当前窗口重新解释原申请原因。
	if head.State == "ready" {
		var bound string
		if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.bind_original_refund_aftercare($1,$2)", w.route, string(origin)).Scan(&bound); err != nil {
			return false, err
		}
		if bound != "bound" {
			return false, service.ErrMetonClosed
		}
	}
	var proof []byte
	if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.original_refund_aftercare_result($1,$2)", w.route, ref).Scan(&proof); err != nil {
		return false, err
	}
	if err := json.Unmarshal(proof, &head); err != nil {
		return false, err
	}
	if head.State == "recorded" {
		return true, nil
	}
	if head.State == "unbound" {
		return false, nil
	}
	if head.State != "verification_proved" {
		return false, service.ErrMetonClosed
	}
	var result string
	err := cashSourceResult(ctx, w.source, &result, "SELECT to_jsonb(meton_ledger.apply_original_refund_verification($1,$2,$3))", w.route, ref, string(proof))
	if err != nil {
		return false, err
	}
	if result != "recorded" && result != "superseded" && result != "original_unavailable" {
		return false, service.ErrMetonClosed
	}
	return false, nil
}

// 只由受信审核组合方装配独立角色连接。会员、收银台和渠道通知处理器没有该对象。
type refundPayerReviewStore struct {
	archive *sql.DB
	cipher  cipher.AEAD
	route   json.RawMessage
	keyRef  string
}

/** record 保存人工核验的原材料及其摘要。提交异常仍是未知，重试只能用原操作和原材料。 */
func (s *refundPayerReviewStore) record(ctx context.Context, ref, op uuid.UUID, facts json.RawMessage, material []byte) error {
	return s.recordMaterial(ctx, ref, op, facts, material, payerReview)
}

/** recordMaterial 对两类审核材料共用加密和原操作提交，域与受限数据库入口由程序固定选择。 */
func (s *refundPayerReviewStore) recordMaterial(ctx context.Context, ref, op uuid.UUID, facts json.RawMessage, material []byte, kind refundReviewKind) error {
	if s == nil || s.archive == nil {
		return service.ErrMetonClosed
	}
	tx, err := s.archive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return err
	}
	basis, sealed, query, err := s.sealMaterial(ctx, tx, ref, op, facts, material, kind, s.route)
	if err != nil {
		return err
	}
	var state string
	if err = tx.QueryRowContext(ctx, query,
		string(s.route), ref, op, basis, s.keyRef, sealed).Scan(&state); err != nil {
		return err
	}
	if state != "recorded" {
		return service.ErrMetonClosed
	}
	return tx.Commit()
}

/** 原审核与人员接缝共用同一加密格式；域和原路由参与认证，材料不能移给另一原案或审核种类。 */
func (s *refundPayerReviewStore) sealMaterial(ctx context.Context, tx *sql.Tx, ref, op uuid.UUID, facts json.RawMessage, material []byte, kind refundReviewKind, route json.RawMessage) (string, []byte, string, error) {
	if s == nil || s.cipher == nil || s.cipher.NonceSize() != 12 || s.cipher.Overhead() != 16 || s.keyRef == "" ||
		len(material) == 0 || len(material) > 512*1024 || len(facts) == 0 || len(facts) > 8192 {
		return "", nil, "", service.ErrMetonClosed
	}
	var fields struct{ MaterialHash string }
	if err := json.Unmarshal(facts, &fields); err != nil {
		return "", nil, "", service.ErrMetonClosed
	}
	hash := sha256.Sum256(material)
	if fields.MaterialHash != hex.EncodeToString(hash[:]) {
		return "", nil, "", service.ErrMetonClosed
	}
	var basis string
	if err := tx.QueryRowContext(ctx, "SELECT $1::jsonb::text", string(facts)).Scan(&basis); err != nil {
		return "", nil, "", err
	}
	digest := sha256.Sum256([]byte(basis))
	aad, query, err := reviewMaterialAAD(kind, route, ref, op, s.keyRef, hex.EncodeToString(digest[:]))
	if err != nil {
		return "", nil, "", err
	}
	clear, err := json.Marshal(struct {
		Format   int    `json:"format_version"`
		Facts    string `json:"facts"`
		Material []byte `json:"material"`
	}{1, basis, material})
	if err != nil {
		return "", nil, "", err
	}
	nonce := make([]byte, s.cipher.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return "", nil, "", err
	}
	sealed := s.cipher.Seal(nonce, nonce, clear, aad)
	return basis, sealed, query, nil
}

/** reviewMaterialAAD 写入与离线恢复共用原认证格式；路由和规范事实沿原字节，不能用当前身份重新构造。 */
func reviewMaterialAAD(kind refundReviewKind, route json.RawMessage, ref, op uuid.UUID, keyRef, digest string) ([]byte, string, error) {
	domain := "meton.refund.payer-review.v1"
	query := "SELECT meton_inbox.record_original_payer_review($1,$2,$3,$4,$5,$6)"
	switch kind {
	case payerReview:
	case alternativeReview:
		domain = "meton.refund.alternative-approval.v1"
		query = "SELECT meton_inbox.record_original_alternative_approval($1,$2,$3,$4,$5,$6)"
	case cashDisputeReview:
		domain = "meton.cash.dispute.review.v1"
		query = "SELECT meton_inbox.record_cash_dispute_review($1,$2,$3,$4,$5,$6)"
	default:
		return nil, "", service.ErrMetonClosed
	}
	aad, err := json.Marshal([]any{domain, route, ref, op, keyRef, digest})
	return aad, query, err
}
