//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

/** RecordIsolatedExternalReturn 先可靠保存已验原文和规范事实；来源暂缺原单也不能丢弃渠道强制返还。 */
func (s *cashNoticeStore) RecordIsolatedExternalReturn(ctx context.Context, facts *payment.ExternalCashReturn, original []byte, headers http.Header, publicKey string) error {
	if !s.cfg.IsolatedExternalReturns || !s.cfg.Route.Valid() || facts == nil || s.cipher == nil {
		return service.ErrMetonClosed
	}
	raw, err := json.Marshal(facts)
	if err != nil {
		return service.ErrMetonClosed
	}
	tx, err := s.archive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return service.ErrMetonClosed
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return service.ErrMetonClosed
	}
	// 与原归档函数使用同一 jsonb 规范字节，不用 Go 字段顺序伪造另一个摘要。
	var basis string
	if err = tx.QueryRowContext(ctx, "SELECT jsonb_build_object('app',$1::text,'facts',$2::jsonb)::text", s.cfg.Route.App, string(raw)).Scan(&basis); err != nil {
		return service.ErrMetonClosed
	}
	digest := sha256.Sum256([]byte(basis))
	clear, err := json.Marshal(struct {
		Version   int             `json:"version"`
		Protocol  string          `json:"protocol"`
		Basis     string          `json:"basis"`
		Raw       []byte          `json:"raw"`
		Headers   http.Header     `json:"signatureHeaders"`
		PublicKey string          `json:"platformPublicKey"`
		Writer    json.RawMessage `json:"writer"`
	}{1, "meton.isolated.cash-return.v1", basis, original, headers, publicKey, s.wire})
	if err != nil {
		return service.ErrMetonClosed
	}
	aad, err := cashNoticeAAD(s.cfg, "external_return", facts.Reference, s.cfg.KeyRef, digest[:])
	if err != nil {
		return service.ErrMetonClosed
	}
	nonce := make([]byte, s.cipher.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return service.ErrMetonClosed
	}
	sealed := s.cipher.Seal(nonce, nonce, clear, aad)
	signedHash := sha256.Sum256(original)
	var state string
	err = tx.QueryRowContext(ctx, "SELECT meton_inbox.accept_external_cash_return($1,$2,$3,$4,$5,$6) WHERE meton_inbox.system_id()=$7",
		string(s.wire), string(raw), signedHash[:], headers.Get("Wechatpay-Serial"), s.cfg.KeyRef, sealed, s.cfg.InboxSystem).Scan(&state)
	if err != nil || tx.Commit() != nil {
		return service.ErrMetonClosed
	}
	switch state {
	case "accepted":
		return nil
	case "review":
		return payment.ErrCashNoticeConflict
	default:
		return service.ErrMetonClosed
	}
}
