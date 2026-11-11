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
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

const memberDisputeSignature = "meton_inbox.member_cash_dispute(jsonb,text,bytea)"
const memberDisputeDomain = "meton.cash.dispute.member-material.v1"

type memberDisputeStore struct {
	archive *sql.DB
	cipher  cipher.AEAD
	keyRef  string
}

/** openMemberDispute 固定独立归档及专用材料身份；配置不全时不回退到来源库或审核角色。 */
func openMemberDispute(base string, cfg checkoutConfig, sourceRoles map[string]bool) (*memberDisputeStore, error) {
	dsn, err := readFile(base, cfg.DisputeArchiveDSN, 32768)
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	aead, err := loadCashRecoveryKey(base, cfg.DisputeCipherFile)
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	db, err := sql.Open("postgres", strings.TrimSpace(string(dsn)))
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	system, role, err := checkCashArchive(ctx, db, []string{memberDisputeSignature})
	if err != nil || system != cfg.DisputeArchiveSystem || sourceRoles[role] {
		db.Close()
		return nil, service.ErrMetonClosed
	}
	return &memberDisputeStore{archive: db, cipher: aead, keyRef: cfg.DisputeCipherRef}, nil
}

/** memberDispute 在原会话锁内提交独立材料，随后重新复验来源准入；归档提交失败或来源应答丢失均返回未知。 */
func (s *memberDisputeStore) apply(ctx context.Context, source *sql.Tx, function, proof, action string, wire []byte, a service.CheckoutAccess) (string, error) {
	if s == nil || s.archive == nil || s.cipher == nil {
		return "", service.ErrMetonClosed
	}
	var p struct {
		Facts struct{ Request json.RawMessage }
	}
	var q struct{ MemberDispute service.MemberDisputeRequest }
	if json.Unmarshal([]byte(proof), &p) != nil || json.Unmarshal(wire, &q) != nil {
		return "", service.ErrMetonClosed
	}
	tx, err := s.archive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return "", err
	}
	var key any
	var sealed any
	if action == "dispute_submit" {
		var canonical string
		if err = tx.QueryRowContext(ctx, "SELECT $1::jsonb::text", string(p.Facts.Request)).Scan(&canonical); err != nil {
			return "", err
		}
		blob, err := s.seal(canonical, q.MemberDispute.Material)
		if err != nil {
			return "", err
		}
		key, sealed = s.keyRef, blob
	}
	var result string
	if err = tx.QueryRowContext(ctx, "SELECT meton_inbox.member_cash_dispute($1,$2,$3)", proof, key, sealed).Scan(&result); err != nil {
		return "", err
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	// 该查询不重新提交材料。即便归档已提交，只要当前登录或权限过期，就让调用者按原号核对。
	var checked sql.NullString
	if err = source.QueryRowContext(ctx, "SELECT "+function+"($1,$2,$3,$4,$5,$6)", string(wire), a.Key, a.Creator, a.Revision, a.UntilMS, a.Witness).Scan(&checked); err != nil {
		return "", err
	}
	if !checked.Valid {
		return "", service.ErrMetonClosed
	}
	return result, nil
}

/** seal 将原账号、案件、操作及材料摘要放入认证附加数据，密文不能移给另一笔申诉。 */
func (s *memberDisputeStore) seal(canonical string, material []byte) ([]byte, error) {
	var facts struct{ MaterialHash string }
	hash := sha256.Sum256(material)
	if json.Unmarshal([]byte(canonical), &facts) != nil || facts.MaterialHash != hex.EncodeToString(hash[:]) || len(material) < 1 || len(material) > service.MemberDisputeMaterialLimit {
		return nil, service.ErrMetonClosed
	}
	digest := sha256.Sum256([]byte(canonical))
	aad, _ := json.Marshal([]any{memberDisputeDomain, s.keyRef, hex.EncodeToString(digest[:])})
	clear, _ := json.Marshal(struct {
		Format   int    `json:"format_version"`
		Material []byte `json:"material"`
	}{1, material})
	nonce := make([]byte, s.cipher.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return s.cipher.Seal(nonce, nonce, clear, aad), nil
}

/** readDisputeSubmission 只有已装配的当前审核身份可读材料，并核对原摘要；不向会员回传审核材料或密钥。 */
func (s *refundPayerReviewStore) readDisputeSubmission(ctx context.Context, ref, op uuid.UUID) ([]byte, error) {
	var raw []byte
	if err := s.archive.QueryRowContext(ctx, "SELECT meton_inbox.cash_dispute_submission_material($1,$2,$3)", s.route, ref, op).Scan(&raw); err != nil {
		return nil, err
	}
	var saved struct {
		Request json.RawMessage
		KeyRef  string
		Sealed  []byte
	}
	if json.Unmarshal(raw, &saved) != nil || saved.KeyRef != s.keyRef || len(saved.Sealed) < 29 || s.cipher == nil {
		return nil, service.ErrMetonClosed
	}
	var canonical string
	if err := s.archive.QueryRowContext(ctx, "SELECT $1::jsonb::text", string(saved.Request)).Scan(&canonical); err != nil {
		return nil, err
	}
	digest := sha256.Sum256([]byte(canonical))
	aad, _ := json.Marshal([]any{memberDisputeDomain, saved.KeyRef, hex.EncodeToString(digest[:])})
	clear, err := s.cipher.Open(nil, saved.Sealed[:12], saved.Sealed[12:], aad)
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	var body struct {
		Format   int `json:"format_version"`
		Material []byte
	}
	var facts struct {
		Dispute, Operation uuid.UUID
		MaterialHash       string
	}
	if json.Unmarshal(clear, &body) != nil || body.Format != 1 || json.Unmarshal(saved.Request, &facts) != nil || facts.Dispute != ref || facts.Operation != op {
		return nil, service.ErrMetonClosed
	}
	hash := sha256.Sum256(body.Material)
	if facts.MaterialHash != hex.EncodeToString(hash[:]) {
		return nil, service.ErrMetonClosed
	}
	return body.Material, nil
}
