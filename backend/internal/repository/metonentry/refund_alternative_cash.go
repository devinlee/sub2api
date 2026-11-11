//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/payment/provider"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type alternativeCashConfig struct {
	Version   int    `json:"format_version"`
	SenderDSN string `json:"sender_dsn_file"`
	Endpoint  string `json:"endpoint"`
	Merchant  string `json:"merchant"`
	Signer    string `json:"signing_key_file"`
	Verifier  string `json:"verifier_key_file"`
}
type alternativeCashChannel interface {
	SendAlternativeCash(context.Context, payment.AlternativeCashTarget) (*payment.AlternativeCashProof, error)
	QueryAlternativeCash(context.Context, payment.AlternativeCashTarget) (*payment.AlternativeCashProof, error)
	CloseAlternativeCash(context.Context, payment.AlternativeCashTarget) (*payment.AlternativeCashProof, error)
}
type alternativeCashDelivery struct {
	worker   *refundSettlementWorker
	sender   *sql.DB
	receiver *cashNoticeStore
	channel  alternativeCashChannel
}
type alternativeIOProof struct {
	State string
	Facts struct {
		Mode       string
		ValidUntil time.Time
		Proposal   json.RawMessage
	}
}

/** openAlternativeCash 复用原结清角色及原现金发送者，额外配置缺省关闭，不向会员接口开放现金写入口。 */
func openAlternativeCash(path string, w *refundSettlementWorker, n *cashNoticeStore) (*alternativeCashDelivery, error) {
	if path == "" {
		return nil, nil
	}
	bad := service.ErrMetonClosed
	if n.cipher == nil || n.cipher.NonceSize() != 12 || n.cipher.Overhead() != 16 || !noticeKeyRef.MatchString(n.cfg.KeyRef) {
		return nil, bad
	}
	raw, err := readFile("", path, 32768)
	var c alternativeCashConfig
	if err != nil || metonexecution.DecodeStrict(raw, &c) != nil || c.Version != 1 {
		return nil, bad
	}
	base := filepath.Dir(path)
	key := func(file string) ([]byte, error) {
		b, e := readFile(base, file, 8192)
		if e != nil {
			return nil, e
		}
		return base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
	}
	signer, se := key(c.Signer)
	verifier, ve := key(c.Verifier)
	if se != nil || ve != nil {
		return nil, bad
	}
	channel, err := provider.NewIsolatedAlternativeCash(c.Endpoint, c.Merchant, ed25519.PrivateKey(signer), ed25519.PublicKey(verifier))
	if err != nil {
		return nil, bad
	}
	dsn, err := readFile(base, c.SenderDSN, 32768)
	if err != nil {
		return nil, bad
	}
	pool, err := sql.Open("postgres", strings.TrimSpace(string(dsn)))
	if err != nil {
		return nil, bad
	}
	pool.SetMaxOpenConns(2)
	pool.SetMaxIdleConns(1)
	pool.SetConnMaxLifetime(5 * time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	system, _, err := checkCashArchive(ctx, pool, refundArchiveFunctions)
	var ready bool
	if err != nil || system != n.cfg.InboxSystem || pool.QueryRowContext(ctx, "SELECT meton_inbox.refund_dispatch_ready($1)", w.route).Scan(&ready) != nil || !ready {
		pool.Close()
		return nil, bad
	}
	return &alternativeCashDelivery{worker: w, sender: pool, receiver: n, channel: channel}, nil
}

/** next 领取和确认绑定原任务租约；领取本身从不授予再次发送的资格。 */
func (d *alternativeCashDelivery) next(ctx context.Context) (bool, error) {
	var job *struct{ Refund, Token uuid.UUID }
	if err := cashSourceResult(ctx, d.worker.archive, &job, "SELECT coalesce(meton_inbox.claim_alternative_cash($1),'null'::jsonb)", d.worker.route); err != nil || job == nil {
		return false, err
	}
	state, err := d.execute(ctx, job.Refund)
	if err != nil {
		return true, err
	}
	var finished bool
	err = cashSourceResult(ctx, d.worker.archive, &finished, "SELECT to_jsonb(meton_inbox.finish_alternative_cash($1,$2,$3,$4))", d.worker.route, job.Refund, job.Token, state)
	return true, err
}

/** execute 持久发送声明应答不明时不重发；即使 POST 说成功，也仍等待独立的 GET 现金凭证。 */
func (d *alternativeCashDelivery) execute(ctx context.Context, ref uuid.UUID) (string, error) {
	w := d.worker
	var raw json.RawMessage
	var p alternativeIOProof
	for pass := 0; pass < 3; pass++ {
		if err := cashSourceResult(ctx, w.archive, &raw, "SELECT meton_inbox.prepare_alternative_cash($1,$2)", w.route, ref); err != nil {
			return "", err
		}
		if err := json.Unmarshal(raw, &p); err != nil {
			return "", err
		}
		if p.State != "recorded" {
			break
		}
	}
	if p.State == "stopped" {
		return "closed", nil
	}
	if p.State != "ready" {
		if p.State == "review" {
			return "review", nil
		}
		return "pending", nil
	}
	var proposal struct {
		Refund  uuid.UUID
		Payment payment.AlternativeCashTarget
	}
	if json.Unmarshal(p.Facts.Proposal, &proposal) != nil || proposal.Refund != ref || !proposal.Payment.Valid() || p.Facts.ValidUntil.IsZero() {
		return "", service.ErrMetonClosed
	}
	bounded, cancel := context.WithDeadline(ctx, p.Facts.ValidUntil)
	defer cancel()
	if p.Facts.Mode == "query" || p.Facts.Mode == "close" {
		verb := "GET"
		call := d.channel.QueryAlternativeCash
		if p.Facts.Mode == "close" {
			verb = "CLOSE"
			call = d.channel.CloseAlternativeCash
		}
		proof, err := call(bounded, proposal.Payment)
		if err != nil || proof == nil {
			return "pending", nil
		}
		err = withRefundArchive(ctx, d.sender, func(tx *sql.Tx) error { return d.save(ctx, tx, raw, ref, verb, proof) })
		if err != nil {
			return "", err
		}
		if verb == "CLOSE" {
			return "pending", nil
		}
		if proof.Fact.State == "succeeded" {
			return "success", nil
		}
		if proof.Fact.State == "closed" {
			return "closed", nil
		}
		return "pending", nil
	}
	if p.Facts.Mode != "send" {
		return "", service.ErrMetonClosed
	}
	var source json.RawMessage
	if err := cashSourceResult(ctx, w.source, &source, "SELECT meton_ledger.original_alternative_cash_permit($1,$2,$3)", w.route, ref, string(p.Facts.Proposal)); err != nil {
		return "", err
	}
	var head struct{ State string }
	if json.Unmarshal(source, &head) != nil || head.State != "source_ready" {
		return "review", nil
	}
	var secret sql.NullString
	err := withRefundArchive(ctx, d.sender, func(tx *sql.Tx) error {
		return tx.QueryRowContext(ctx, "SELECT meton_inbox.begin_alternative_cash($1,$2)", string(raw), string(source)).Scan(&secret)
	})
	if err != nil {
		return "", err
	}
	if !secret.Valid {
		return "pending", nil
	}
	err = withRefundArchive(ctx, d.sender, func(tx *sql.Tx) error {
		var allowed bool
		if e := tx.QueryRowContext(ctx, "SELECT meton_inbox.hold_alternative_cash($1,$2)", string(raw), secret.String).Scan(&allowed); e != nil {
			return e
		}
		if !allowed {
			return nil
		}
		// 顺序与原结清相同：先归档原现金锁，再来源原份额锁。实际 HTTP 期间保留两边的当前权限，恢复换代须等待旧执行退出。
		src, e := w.source.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
		if e != nil {
			return e
		}
		defer src.Rollback()
		if _, e = src.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); e != nil {
			return e
		}
		if e = src.QueryRowContext(ctx, "SELECT meton_ledger.original_alternative_cash_permit($1,$2,$3)", w.route, ref, string(p.Facts.Proposal)).Scan(&source); e != nil {
			return e
		}
		if json.Unmarshal(source, &head) != nil || head.State != "source_ready" {
			return nil
		}
		proof, e := d.channel.SendAlternativeCash(bounded, proposal.Payment)
		if e == nil && proof != nil {
			if e = d.save(ctx, tx, raw, ref, "POST", proof); e != nil {
				return e
			}
		}
		// 来源许可没有资金写入；HTTP 错误保持可能已发，绝不按失败释放 R。
		return src.Commit()
	})
	return "pending", err
}

/** save 在独立归档保存验签原文与当时公钥；加密 AAD 将其固定到原账号路由、原退款和方法。 */
func (d *alternativeCashDelivery) save(ctx context.Context, tx *sql.Tx, permission json.RawMessage, ref uuid.UUID, verb string, proof *payment.AlternativeCashProof) error {
	clear, err := json.Marshal(proof)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(clear)
	aad, err := json.Marshal([]any{"meton.refund.alternative-cash.v1", json.RawMessage(d.worker.route), ref, verb, d.receiver.cfg.KeyRef, hex.EncodeToString(digest[:])})
	if err != nil {
		return err
	}
	nonce := make([]byte, d.receiver.cipher.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	sealed := d.receiver.cipher.Seal(nonce, nonce, clear, aad)
	facts, err := json.Marshal(proof.Fact)
	if err != nil {
		return err
	}
	var state string
	if err = tx.QueryRowContext(ctx, "SELECT meton_inbox.record_alternative_cash($1,$2,$3,$4,$5,$6)", string(permission), verb, string(facts), digest[:], d.receiver.cfg.KeyRef, sealed).Scan(&state); err != nil {
		return err
	}
	if state != "recorded" {
		return service.ErrMetonClosed
	}
	return nil
}
