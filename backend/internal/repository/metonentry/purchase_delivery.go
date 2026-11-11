//go:build meton_managed

package metonentry

import (
	"bytes"
	"context"
	"crypto"
	"crypto/cipher"
	"crypto/rsa"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
	"github.com/wechatpay-apiv3/wechatpay-go/utils"
)

const cashObserve = "meton_ledger.observe_cash_payment(text,text,bigint,jsonb,jsonb)"
const cashFulfil = "meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)"
const refundObserve = "meton_ledger.observe_original_refund(text,text,bigint,jsonb,jsonb)"

type purchaseWorkerConfig struct {
	Version        int               `json:"format_version"`
	SourceDSN      string            `json:"source_dsn_file"`
	InboxDSN       string            `json:"inbox_dsn_file"`
	OriginIndexDSN string            `json:"origin_index_dsn_file,omitempty"`
	PreviousKeys   map[string]string `json:"previous_recovery_keys,omitempty"`
	QueryWindow    int               `json:"original_query_window_seconds,omitempty"`
	CloseWindow    int               `json:"close_reconcile_window_seconds,omitempty"`
	RefundFailures bool              `json:"verified_refund_failures,omitempty"`
}
type purchaseWorker struct {
	n               *cashNoticeStore
	source, archive *sql.DB
	originIndex     *sql.DB
	keys            map[string]cipher.AEAD
	channel         *service.MetonCashNotifications
	queryWindow     int
	closeWindow     int
	refundFailures  bool
}
type purchaseClaim struct {
	receipt, lease uuid.UUID
	hash           []byte
}
type purchaseProof struct {
	Notice payment.CashNotice `json:"notice"`
	Origin json.RawMessage    `json:"origin"`
	basis  []byte
}
type purchaseOutcome struct{ state, reason string }

/** StartPurchaseDelivery 只从原收件库消费本渠道已验付款。退出时先取消并等待在途工作，再释放角色连接。 */
func StartPurchaseDelivery(path string, notices *service.MetonCashNotifications) (func(), error) {
	noop := func() {}
	if path == "" {
		return noop, nil
	}
	if notices == nil {
		return noop, service.ErrMetonClosed
	}
	n, ok := notices.Store.(*cashNoticeStore)
	var cfg purchaseWorkerConfig
	raw, err := readFile("", path, 32768)
	if !ok || err != nil || metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.Version != 1 || len(cfg.PreviousKeys) > 32 ||
		cfg.QueryWindow != 0 && (cfg.QueryWindow < 60 || cfg.QueryWindow > 2678400) ||
		cfg.CloseWindow != 0 && (cfg.QueryWindow == 0 || cfg.CloseWindow < 60 || cfg.CloseWindow > 2678400) {
		return noop, service.ErrMetonClosed
	}
	w := &purchaseWorker{n: n, keys: map[string]cipher.AEAD{n.cfg.KeyRef: n.cipher}, channel: notices, queryWindow: cfg.QueryWindow, closeWindow: cfg.CloseWindow, refundFailures: cfg.RefundFailures}
	base := filepath.Dir(path)
	for ref, path := range cfg.PreviousKeys {
		if !noticeKeyRef.MatchString(ref) || ref == n.cfg.KeyRef {
			return noop, service.ErrMetonClosed
		}
		key, err := loadCashRecoveryKey(base, path)
		if err != nil {
			return noop, err
		}
		w.keys[ref] = key
	}
	closeDB := func() {
		if w.source != nil {
			w.source.Close()
		}
		if w.archive != nil {
			w.archive.Close()
		}
		if w.originIndex != nil {
			w.originIndex.Close()
		}
	}
	for _, item := range []struct {
		ref string
		dst **sql.DB
	}{{cfg.SourceDSN, &w.source}, {cfg.InboxDSN, &w.archive}} {
		material, err := readFile(base, item.ref, 32768)
		if err != nil {
			closeDB()
			return noop, service.ErrMetonClosed
		}
		db, err := sql.Open("postgres", strings.TrimSpace(string(material)))
		if err != nil {
			closeDB()
			return noop, service.ErrMetonClosed
		}
		*item.dst = db
		db.SetMaxOpenConns(3)
		db.SetMaxIdleConns(1)
		db.SetConnMaxLifetime(5 * time.Minute)
	}
	check, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sourceFunctions := []string{cashObserve, cashFulfil, refundObserve, "meton_ledger.notification_system_id()", restoredCashProofScope}
	archiveFunctions := []string{"meton_inbox.lock_purchase_consumer(jsonb)",
		"meton_inbox.claim_purchase_notice(jsonb)", "meton_inbox.read_purchase_notice(jsonb,uuid,bytea,uuid)",
		"meton_inbox.finish_purchase_notice(jsonb,uuid,bytea,uuid,text,text)", "meton_inbox.claim_refund_notice(jsonb)",
		"meton_inbox.read_refund_notice(jsonb,uuid,bytea,uuid)", "meton_inbox.original_refund_proof(jsonb,text,text)",
		"meton_inbox.index_original_refund(jsonb,uuid,bytea,uuid,text,text,bytea)"}
	if cfg.QueryWindow > 0 {
		sourceFunctions = append(sourceFunctions, "meton_ledger.claim_original_cash_query(jsonb,integer)", "meton_ledger.finish_original_cash_query(jsonb,uuid,uuid,uuid,text)")
		archiveFunctions = append(archiveFunctions, "meton_inbox.accept_payment_query(jsonb,text,bytea,bytea,text,text,bytea)",
			"meton_inbox.claim_payment_query(jsonb)", "meton_inbox.read_payment_query(jsonb,uuid,bytea,uuid)")
	}
	if cfg.CloseWindow > 0 {
		sourceFunctions = append(sourceFunctions, "meton_ledger.claim_order_stop(jsonb,integer)",
			"meton_ledger.advance_order_stop(jsonb,uuid,uuid,uuid,bigint,text,uuid,bytea)", "meton_ledger.current_order_close(jsonb,uuid,uuid,uuid,bigint,uuid)")
		archiveFunctions = append(archiveFunctions, "meton_inbox.record_order_stop_proof(jsonb,uuid,uuid,text,text,text,bytea,text,text,bytea)",
			"meton_inbox.take_order_close(jsonb,uuid,uuid,text,text,uuid,bytea)")
	}
	if cfg.RefundFailures {
		sourceFunctions = append(sourceFunctions, "meton_ledger.apply_verified_refund_failure(jsonb,jsonb)")
		archiveFunctions = append(archiveFunctions, "meton_inbox.capture_refund_terminal(jsonb,uuid,bytea,uuid,bytea)",
			"meton_inbox.original_refund_failure(jsonb,uuid,bytea,uuid)")
	}
	_, sourceRole, err := checkPoolPermissions(w.source, sourceFunctions)
	system, archiveRole, archiveErr := checkCashArchive(check, w.archive, archiveFunctions)
	var primary string
	if err != nil || archiveErr != nil || system != n.cfg.InboxSystem || sourceRole == archiveRole || !giftPoolSeparate(w.source) || !resultPoolPrivate(w.source) ||
		w.source.QueryRowContext(check, "SELECT meton_ledger.notification_system_id()").Scan(&primary) != nil || primary != n.cfg.SourceSystem {
		closeDB()
		return noop, service.ErrMetonClosed
	}
	if _, err = w.archive.ExecContext(check, "SELECT meton_inbox.lock_purchase_consumer($1)", string(n.wire)); err != nil {
		closeDB()
		return noop, service.ErrMetonClosed
	}
	if err = w.openNoticeOriginIndex(check, base, cfg.OriginIndexDSN, sourceRole, archiveRole); err != nil {
		closeDB()
		return noop, service.ErrMetonClosed
	}
	ctx, stop := context.WithCancel(context.Background())
	var group sync.WaitGroup
	launch := func(step func(context.Context) (bool, error)) {
		group.Add(1)
		go func() { defer group.Done(); runCashWorker(ctx, step) }()
	}
	launch(func(ctx context.Context) (bool, error) { return w.next(ctx, "payment") })
	launch(func(ctx context.Context) (bool, error) { return w.next(ctx, "refund") })
	if w.originIndex != nil {
		launch(w.indexNextNoticeOrigin)
	}
	if w.queryWindow > 0 {
		launch(w.queryNextOriginal)
		launch(func(ctx context.Context) (bool, error) { return w.next(ctx, "payment_query") })
	}
	if w.closeWindow > 0 {
		launch(w.stopNextOriginal)
	}
	return func() { stop(); group.Wait(); closeDB() }, nil
}

/** runCashWorker 有界领取；一笔回执响应丢失时重查原事实。多个节点可同时工作，过期票据不能覆盖新的处理结果。 */
func runCashWorker(ctx context.Context, next func(context.Context) (bool, error)) {
	for ctx.Err() == nil {
		delay := time.Second
		for i := 0; i < 8 && ctx.Err() == nil; i++ {
			step, cancel := context.WithTimeout(ctx, 5*time.Second)
			worked, err := next(step)
			cancel()
			if err != nil {
				delay = 3 * time.Second
				break
			}
			if !worked {
				break
			}
			if i == 7 {
				delay = 0
			}
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (w *purchaseWorker) next(ctx context.Context, kind string) (bool, error) {
	wire := string(w.n.wire)
	var c purchaseClaim
	claim := "SELECT receipt_id,proof_hash,lease FROM meton_inbox.claim_purchase_notice($1)"
	read := "SELECT delivery,key_ref,sealed,conflicted FROM meton_inbox.read_purchase_notice($1,$2,$3,$4)"
	switch kind {
	case "payment_query":
		claim = "SELECT receipt_id,proof_hash,lease FROM meton_inbox.claim_payment_query($1)"
		read = "SELECT delivery,key_ref,sealed,conflicted FROM meton_inbox.read_payment_query($1,$2,$3,$4)"
	case "refund":
		claim = "SELECT receipt_id,proof_hash,lease FROM meton_inbox.claim_refund_notice($1)"
		read = "SELECT delivery,key_ref,sealed,conflicted FROM meton_inbox.read_refund_notice($1,$2,$3,$4)"
	}
	err := w.archive.QueryRowContext(ctx, claim, wire).Scan(&c.receipt, &c.hash, &c.lease)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	tx, err := w.archive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return true, err
	}
	defer tx.Rollback()
	var delivery, keyRef string
	var sealed []byte
	var conflict bool
	err = tx.QueryRowContext(ctx, read,
		wire, c.receipt, c.hash, c.lease).Scan(&delivery, &keyRef, &sealed, &conflict)
	if err != nil {
		return true, err
	}
	var result purchaseOutcome
	if conflict && kind != "refund" {
		result = purchaseOutcome{"review", "conflicting_delivery"}
	} else {
		proof, state := w.openProof(kind, delivery, keyRef, c.hash, sealed)
		if state != nil {
			result = *state
		} else if kind == "refund" {
			result = w.consumeRefund(ctx, tx, c, proof)
		} else {
			result = w.guardedPost(ctx, tx, proof)
		}
	}
	var saved bool
	err = tx.QueryRowContext(ctx, "SELECT meton_inbox.finish_purchase_notice($1,$2,$3,$4,$5,$6)",
		wire, c.receipt, c.hash, c.lease, result.state, result.reason).Scan(&saved)
	if err != nil {
		return true, err
	}
	if !saved {
		return true, service.ErrMetonClosed
	}
	return true, tx.Commit()
}

/** openProof 已可靠接收的历史通知使用保存的签名时间和当版公钥。新到通知的五分钟时效仍由原入口验真。 */
func (w *purchaseWorker) openProof(kind, delivery, keyRef string, hash, sealed []byte) (*purchaseProof, *purchaseOutcome) {
	key := w.keys[keyRef]
	if key == nil {
		return nil, &purchaseOutcome{"retry", "recovery_key_missing"}
	}
	invalid := &purchaseOutcome{"review", "invalid_proof"}
	aad, err := cashNoticeAAD(w.n.cfg, kind, delivery, keyRef, hash)
	if err != nil || len(sealed) < key.NonceSize()+key.Overhead() {
		return nil, invalid
	}
	clear, err := key.Open(nil, sealed[:key.NonceSize()], sealed[key.NonceSize():], aad)
	if err != nil {
		return nil, invalid
	}
	var original struct {
		Version     int             `json:"version"`
		Basis       json.RawMessage `json:"basis"`
		Raw         []byte          `json:"raw"`
		Headers     http.Header     `json:"signatureHeaders"`
		PublicKey   string          `json:"platformPublicKey"`
		QueryTarget string          `json:"queryTarget"`
		Writer      struct {
			Deployment, Source, SourceSystem, Channel, CashEnvironment, Merchant, App, InboxSystem string
			Epoch                                                                                  int64
		} `json:"writer"`
	}
	if json.Unmarshal(clear, &original) != nil || original.Version != 1 {
		return nil, invalid
	}
	basisHash := sha256.Sum256(original.Basis)
	var basis purchaseProof
	if !bytes.Equal(basisHash[:], hash) || json.Unmarshal(original.Basis, &basis) != nil || len(basis.Origin) == 0 {
		return nil, invalid
	}
	if kind == "refund" {
		if basis.Notice.Kind != "refund" || (basis.Notice.State != "SUCCESS" && basis.Notice.State != "CLOSED" && basis.Notice.State != "ABNORMAL") {
			return nil, invalid
		}
	} else if basis.Notice.Kind != "payment" || basis.Notice.State != "SUCCESS" {
		return nil, invalid
	}
	if kind == "payment_query" {
		expected := "https://api.mch.weixin.qq.com/v3/pay/transactions/out-trade-no/" + url.PathEscape(basis.Notice.Order) + "?mchid=" + url.QueryEscape(basis.Notice.Merchant)
		if basis.Notice.Delivery != "" || basis.Notice.QueryReference() != delivery || original.QueryTarget != expected {
			return nil, invalid
		}
	} else if basis.Notice.Delivery != delivery || original.QueryTarget != "" {
		return nil, invalid
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(original.Headers.Get("Wechatpay-Signature"))
	public, e := utils.LoadPublicKey(original.PublicKey)
	signed := sha256.Sum256([]byte(original.Headers.Get("Wechatpay-Timestamp") + "\n" + original.Headers.Get("Wechatpay-Nonce") + "\n" + string(original.Raw) + "\n"))
	if e != nil || err != nil || rsa.VerifyPKCS1v15(public, crypto.SHA256, signed[:], signature) != nil {
		return nil, invalid
	}
	c := w.n.cfg
	r := original.Writer
	if r.Deployment != c.Environment || r.Source != c.Source || r.Channel != c.Route.Channel || r.CashEnvironment != c.Route.Environment ||
		r.Merchant != c.Route.Merchant || r.App != c.Route.App {
		return nil, &purchaseOutcome{"foreign", "different_scope"}
	}
	if failed := w.historicalPhysicalScope(r.SourceSystem, r.InboxSystem, r.Epoch, basis.Origin); failed != nil {
		return nil, failed
	}
	// 关联索引使用已验密文中的原规范字节，避免字段升级后重新编码改变历史证明摘要。
	basis.basis = append([]byte(nil), original.Basis...)
	return &basis, nil
}

/** applyRefund 仅登记来自原渠道的经济事实；收到终态通知也不能据此发起退款或释放额度。 */
func (w *purchaseWorker) applyRefund(ctx context.Context, proof *purchaseProof) purchaseOutcome {
	var out struct{ State string }
	c := w.n.cfg
	facts, err := json.Marshal(proof.Notice)
	if err != nil {
		return purchaseOutcome{"review", "invalid_facts"}
	}
	err = w.sourceResult(ctx, &out, "SELECT meton_ledger.observe_original_refund($1,$2,$3,$4,$5) WHERE meton_ledger.notification_system_id()=$6",
		c.Environment, c.Source, c.Epoch, string(proof.Origin), string(facts), c.SourceSystem)
	if err != nil || out.State != "review" {
		return purchaseOutcome{"retry", "refund_origin_unconfirmed"}
	}
	return purchaseOutcome{"review", "original_refund_review"}
}

/** consumeRefund 按本次租约补齐旧版密文的交易索引，再交给来源核对，未取到原单也不会遗失已验材料。 */
func (w *purchaseWorker) consumeRefund(ctx context.Context, tx *sql.Tx, claim purchaseClaim, proof *purchaseProof) purchaseOutcome {
	origin, _, err := refundOrderBasis(&proof.Notice, proof.Origin)
	if err != nil {
		return purchaseOutcome{"review", "invalid_refund_origin"}
	}
	basis, err := paymentBasis(&proof.Notice, origin)
	if err != nil {
		return purchaseOutcome{"review", "invalid_refund_origin"}
	}
	canonical := sha256.Sum256(basis)
	_, err = tx.ExecContext(ctx, "SELECT meton_inbox.index_original_refund($1,$2,$3,$4,$5,$6,$7)",
		string(w.n.wire), claim.receipt, claim.hash, claim.lease, proof.Notice.Order, proof.Notice.Transaction, canonical[:])
	if err != nil {
		return purchaseOutcome{"retry", "refund_index_unconfirmed"}
	}
	if !w.refundFailures {
		return w.applyRefund(ctx, proof)
	}
	return w.finishVerifiedFailure(ctx, tx, claim, proof, basis)
}

/** guardedPost 在截点外原交易锁内做来源提交。即使来源回退而独立收件库保留了退款，也必须重新建立原单保护。 */
func (w *purchaseWorker) guardedPost(ctx context.Context, tx *sql.Tx, proof *purchaseProof) purchaseOutcome {
	var state, delivery, keyRef string
	var hash, sealed []byte
	notice := &proof.Notice
	err := tx.QueryRowContext(ctx, "SELECT state,coalesce(delivery,''),coalesce(key_ref,''),digest,sealed FROM meton_inbox.original_refund_proof($1,$2,$3)",
		string(w.n.wire), notice.Order, notice.Transaction).Scan(&state, &delivery, &keyRef, &hash, &sealed)
	if err != nil {
		return purchaseOutcome{"retry", "refund_proof_unconfirmed"}
	}
	switch state {
	case "observed":
		refund, failed := w.openProof("refund", delivery, keyRef, hash, sealed)
		if failed != nil {
			return *failed
		}
		if refund.Notice.Order != notice.Order || refund.Notice.Transaction != notice.Transaction || refund.Notice.Merchant != notice.Merchant {
			return purchaseOutcome{"review", "invalid_refund_reference"}
		}
		if state := w.applyRefund(ctx, refund); state.reason != "original_refund_review" {
			return state
		}
	case "clear":
	case "pending_legacy":
		return purchaseOutcome{"retry", "legacy_refund_pending"}
	case "external_return":
		// 独立归档已记录外部返还；来源快照没有这笔记录也不能重新授予购买额度。
		return purchaseOutcome{"review", "external_cash_return"}
	default:
		return purchaseOutcome{"review", "invalid_refund_reference"}
	}
	return w.post(ctx, proof)
}

/** post 两次来源提交分别表示已付款和已到账，任一提交未知都由同一笔现金重新核对。 */
func (w *purchaseWorker) post(ctx context.Context, proof *purchaseProof) purchaseOutcome {
	retry := purchaseOutcome{"retry", "source_unconfirmed"}
	cfg := w.n.cfg
	facts, err := json.Marshal(proof.Notice)
	if err != nil {
		return purchaseOutcome{"review", "invalid_facts"}
	}
	type response struct {
		Payment  uuid.UUID
		State    string
		Version  int64
		Event    uuid.UUID
		Sequence int64
	}
	var observed response
	query := `SELECT meton_ledger.observe_cash_payment($1,$2,$3,$4,$5) WHERE meton_ledger.notification_system_id()=$6`
	err = w.sourceResult(ctx, &observed, query, cfg.Environment, cfg.Source, cfg.Epoch, string(proof.Origin), string(facts), cfg.SourceSystem)
	if err != nil {
		return retry
	}
	if observed.State == "recovery_review" {
		return purchaseOutcome{"review", "original_disposition_missing"}
	}
	if observed.State == "conflict" || observed.State == "restricted" {
		return purchaseOutcome{"review", "cash_restricted"}
	}
	if observed.Payment == uuid.Nil || observed.Version <= 0 {
		return retry
	}
	var origin struct {
		SourceMarker uuid.UUID
		Intent       uuid.UUID
	}
	if json.Unmarshal(proof.Origin, &origin) != nil || origin.SourceMarker == uuid.Nil || origin.Intent == uuid.Nil {
		return purchaseOutcome{"review", "invalid_origin"}
	}
	var posted response
	query = `SELECT meton_ledger.fulfil_cash_payment($1,$2,$3,$4,$5,$6,$7) WHERE meton_ledger.notification_system_id()=$8`
	err = w.sourceResult(ctx, &posted, query, cfg.Environment, cfg.Source, cfg.Epoch, origin.SourceMarker, origin.Intent, observed.Payment, observed.Version, cfg.SourceSystem)
	if err != nil {
		return retry
	}
	if posted.State == "recovery_review" {
		return purchaseOutcome{"review", "original_disposition_missing"}
	}
	if posted.State == "restricted" {
		return purchaseOutcome{"review", "cash_restricted"}
	}
	if posted.State != "posted" || posted.Event == uuid.Nil || posted.Sequence <= 0 {
		return retry
	}
	return purchaseOutcome{"posted", "original_purchase"}
}

func (w *purchaseWorker) sourceResult(ctx context.Context, dest any, query string, args ...any) error {
	return cashSourceResult(ctx, w.source, dest, query, args...)
}

/** cashSourceResult 只在来源提交成功后交出结果，付款收件和退款派发共用这个事务约束。 */
func cashSourceResult(ctx context.Context, db *sql.DB, dest any, query string, args ...any) error {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return err
	}
	var raw []byte
	if err = tx.QueryRowContext(ctx, query, args...).Scan(&raw); err != nil {
		return err
	}
	if err = json.Unmarshal(raw, dest); err != nil {
		return err
	}
	return tx.Commit()
}
