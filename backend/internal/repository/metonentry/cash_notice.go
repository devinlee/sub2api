//go:build meton_managed

package metonentry

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/lib/pq"
)

const noticeOrigin = "meton_ledger.notification_origin(text,text,bigint,text,text,text,text,jsonb)"
const inboxAppend = "meton_inbox.accept_notice(jsonb,text,text,bytea,bytea,text,text,bytea)"
const refundAppend = "meton_inbox.accept_refund_notice(jsonb,text,text,text,bytea,bytea,bytea,text,text,bytea)"
const inboxMatch = "meton_inbox.previously_received(jsonb,text,text,bytea)"
const externalReturnAppend = "meton_inbox.accept_external_cash_return(jsonb,jsonb,bytea,text,text,bytea)"

type notificationConfig struct {
	Version                 int                          `json:"format_version"`
	Environment             string                       `json:"environment"`
	Source                  string                       `json:"source"`
	Epoch                   int64                        `json:"epoch"`
	Route                   service.CheckoutPaymentRoute `json:"payment_route"`
	Callback                string                       `json:"callback"`
	SourceDSN               string                       `json:"source_dsn_file"`
	InboxDSN                string                       `json:"inbox_dsn_file"`
	SourceSystem            string                       `json:"source_system"`
	InboxSystem             string                       `json:"inbox_system"`
	RecoveryKey             string                       `json:"recovery_key_file"`
	KeyRef                  string                       `json:"recovery_key_ref"`
	IsolatedExternalReturns bool                         `json:"isolated_external_returns"`
}

type cashNoticeStore struct {
	source, archive *sql.DB
	cfg             notificationConfig
	cipher          cipher.AEAD
	wire            []byte
}

var pgSystemNumber = regexp.MustCompile(`^[1-9][0-9]{0,19}$`)
var noticeKeyRef = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,120}$`)

/** OpenCashNotifications 独立装配来源只读与库外追加角色，关闭桌面下单也能继续接收已发原单的通知。 */
func OpenCashNotifications(path string, payments *service.PaymentConfigService) (*service.MetonCashNotifications, func(), error) {
	noop := func() {}
	if path == "" {
		return nil, noop, nil
	}
	raw, err := readFile("", path, 32768)
	var c notificationConfig
	source, ok := service.MetonSource()
	if err != nil || payments == nil || !ok || metonexecution.DecodeStrict(raw, &c) != nil || c.Version != 1 ||
		c.Environment != source.Environment || c.Source != source.Source || c.Epoch != source.Epoch || !c.Route.Valid() ||
		c.IsolatedExternalReturns && c.Route.Environment != "isolated" ||
		!noticeKeyRef.MatchString(c.KeyRef) || !pgSystemNumber.MatchString(c.SourceSystem) ||
		!pgSystemNumber.MatchString(c.InboxSystem) || c.SourceSystem == c.InboxSystem {
		return nil, noop, service.ErrMetonClosed
	}
	callback, err := url.Parse(c.Callback)
	if err != nil || callback.Scheme != "https" || callback.Hostname() == "" || callback.User != nil ||
		callback.String() != "https://"+callback.Host+service.PublicCashWebhook {
		return nil, noop, service.ErrMetonClosed
	}
	base := filepath.Dir(path)
	aead, err := loadCashRecoveryKey(base, c.RecoveryKey)
	if err != nil {
		return nil, noop, service.ErrMetonClosed
	}
	store := &cashNoticeStore{cfg: c, cipher: aead}
	closePools := func() {
		if store.source != nil {
			_ = store.source.Close()
		}
		if store.archive != nil {
			_ = store.archive.Close()
		}
	}
	for _, item := range []struct {
		file string
		dest **sql.DB
	}{{c.SourceDSN, &store.source}, {c.InboxDSN, &store.archive}} {
		data, e := readFile(base, item.file, 32768)
		if e != nil {
			closePools()
			return nil, noop, service.ErrMetonClosed
		}
		db, e := sql.Open("postgres", strings.TrimSpace(string(data)))
		if e != nil {
			closePools()
			return nil, noop, service.ErrMetonClosed
		}
		*item.dest = db
		db.SetMaxOpenConns(8)
		db.SetMaxIdleConns(2)
		db.SetConnMaxLifetime(5 * time.Minute)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, sourceRole, err := checkPoolPermissions(store.source, []string{noticeOrigin, "meton_ledger.notification_system_id()"})
	var sourceSystem, inboxSystem, archiveRole string
	functions := []string{inboxAppend, inboxMatch, refundAppend}
	if c.IsolatedExternalReturns {
		functions = append(functions, externalReturnAppend)
	}
	inboxSystem, archiveRole, archiveErr := checkCashArchive(ctx, store.archive, functions)
	if err != nil || !giftPoolSeparate(store.source) || !resultPoolPrivate(store.source) ||
		store.source.QueryRowContext(ctx, "SELECT meton_ledger.notification_system_id()").Scan(&sourceSystem) != nil || archiveErr != nil ||
		sourceSystem != c.SourceSystem || inboxSystem != c.InboxSystem || archiveRole == sourceRole {
		closePools()
		return nil, noop, service.ErrMetonClosed
	}
	store.wire, err = json.Marshal(map[string]any{"deployment": c.Environment, "source": c.Source, "epoch": c.Epoch, "sourceSystem": sourceSystem,
		"channel": c.Route.Channel, "cashEnvironment": c.Route.Environment, "merchant": c.Route.Merchant, "app": c.Route.App, "inboxSystem": inboxSystem})
	if err != nil {
		closePools()
		return nil, noop, service.ErrMetonClosed
	}
	return &service.MetonCashNotifications{Route: c.Route, Callback: callback, Payments: payments, Store: store,
		IsolatedExternalReturns: c.IsolatedExternalReturns}, closePools, nil
}

/** checkCashArchive 两类角色分别核对自己的完整函数清单，不能直接读写付款证明或兼任另一种用途。 */
func checkCashArchive(ctx context.Context, db *sql.DB, functions []string) (string, string, error) {
	var system, role string
	var private bool
	err := db.QueryRowContext(ctx, `SELECT meton_inbox.system_id(),current_user,
			NOT pg_is_in_recovery() AND current_setting('fsync')='on' AND current_setting('full_page_writes')='on'
			AND NOT EXISTS(SELECT FROM pg_roles WHERE (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls
			    OR rolname IN ('pg_read_all_data','pg_write_all_data','pg_execute_server_program','pg_read_server_files','pg_write_server_files'))
			    AND pg_has_role(current_user,oid,'MEMBER'))
			AND NOT has_schema_privilege(current_user,'meton_inbox','CREATE') AND NOT has_schema_privilege(current_user,'public','CREATE')
			AND NOT EXISTS(SELECT FROM pg_class t JOIN pg_namespace n ON t.relnamespace=n.oid WHERE n.nspname='meton_inbox' AND t.relkind IN ('r','p')
				AND (has_table_privilege(current_user,t.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER') OR has_any_column_privilege(current_user,t.oid,'SELECT,INSERT,UPDATE')))
			AND NOT EXISTS(SELECT FROM unnest($1::text[]) f WHERE to_regprocedure(f) IS NULL OR NOT has_function_privilege(current_user,to_regprocedure(f),'EXECUTE'))
			AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_inbox'
				AND p.oid<>'meton_inbox.system_id()'::regprocedure AND NOT EXISTS(SELECT FROM unnest($1::text[]) f WHERE p.oid=to_regprocedure(f))
				AND has_function_privilege(current_user,p.oid,'EXECUTE'))`, pq.Array(functions)).Scan(&system, &role, &private)
	if err != nil || !private {
		return "", "", service.ErrMetonClosed
	}
	return system, role, nil
}

func loadCashRecoveryKey(base, path string) (cipher.AEAD, error) {
	raw, err := readFile(base, path, 512)
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	return parseCashRecoveryKey(raw)
}

/** parseCashRecoveryKey 运行后台和离线验真使用同一密钥格式；离线核验不需要取得数据库连接。 */
func parseCashRecoveryKey(raw []byte) (cipher.AEAD, error) {
	if len(raw) == 0 || len(raw) > 512 {
		return nil, service.ErrMetonClosed
	}
	key, err := base64.StdEncoding.Strict().DecodeString(strings.TrimSpace(string(raw)))
	defer clear(key)
	if err != nil || len(key) != 32 {
		return nil, service.ErrMetonClosed
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	return cipher.NewGCM(block)
}

func cashNoticeAAD(c notificationConfig, kind, delivery, keyRef string, digest []byte) ([]byte, error) {
	return json.Marshal([]string{"meton.cash.notice.v1", c.Route.Channel, c.Route.Environment, c.Route.Merchant, kind, delivery, keyRef,
		base64.StdEncoding.EncodeToString(digest)})
}

/** RecordNotice 独立收件库提交才可答复。提交响应丢失只返回未知，由重投按原通知查回。 */
func (s *cashNoticeStore) RecordNotice(ctx context.Context, notice *payment.CashNotice, original []byte, signatures http.Header, publicKey string) error {
	facts, err := json.Marshal(notice)
	if err != nil {
		return service.ErrMetonClosed
	}
	c := s.cfg
	signedFacts, err := json.Marshal([]any{c.Route.Channel, c.Route.Environment, c.Route.Merchant, c.Route.App, notice})
	if err != nil {
		return service.ErrMetonClosed
	}
	signedHash := sha256.Sum256(signedFacts)
	origin, err := s.originalCashBasis(ctx, facts)
	if err != nil {
		var pg *pq.Error
		if errors.As(err, &pg) && pg.Code == "22023" {
			return payment.ErrInvalidCashNotice
		}
		// 原单尚未恢复时，当前写者只能确认已经验签且经济字段完全一致的旧收件。
		if errors.As(err, &pg) && pg.Code == "P0002" {
			var seen bool
			e := s.archive.QueryRowContext(ctx, "SELECT meton_inbox.previously_received($1,$2,$3,$4) WHERE meton_inbox.system_id()=$5",
				string(s.wire), notice.Kind, notice.Delivery, signedHash[:], c.InboxSystem).Scan(&seen)
			if e == nil && seen {
				return nil
			}
		}
		return service.ErrMetonClosed
	}
	var legacy []byte
	if notice.Kind == "refund" {
		origin, legacy, err = refundOrderBasis(notice, origin)
		if err != nil {
			return service.ErrMetonClosed
		}
	}
	digest, sealed, err := s.sealPaymentProof(notice.Kind, notice.Delivery, notice, origin, original, signatures, publicKey, "")
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
	var state string
	if notice.Kind == "refund" {
		err = tx.QueryRowContext(ctx, "SELECT meton_inbox.accept_refund_notice($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) WHERE meton_inbox.system_id()=$11",
			string(s.wire), notice.Delivery, notice.Order, notice.Transaction, digest, legacy, signedHash[:], signatures.Get("Wechatpay-Serial"), c.KeyRef, sealed, c.InboxSystem).Scan(&state)
	} else {
		err = tx.QueryRowContext(ctx, "SELECT meton_inbox.accept_notice($1,$2,$3,$4,$5,$6,$7,$8) WHERE meton_inbox.system_id()=$9",
			string(s.wire), notice.Kind, notice.Delivery, digest, signedHash[:], signatures.Get("Wechatpay-Serial"), c.KeyRef, sealed, c.InboxSystem).Scan(&state)
	}
	if err != nil || tx.Commit() != nil {
		return service.ErrMetonClosed
	}
	switch state {
	case "accepted":
		return nil
	case "conflict":
		return payment.ErrCashNoticeConflict
	default:
		return service.ErrMetonClosed
	}
}

func (s *cashNoticeStore) originalCashBasis(ctx context.Context, facts []byte) ([]byte, error) {
	c := s.cfg
	var origin []byte
	err := s.source.QueryRowContext(ctx, `SELECT meton_ledger.notification_origin($1,$2,$3,$4,$5,$6,$7,$8)
		WHERE meton_ledger.notification_system_id()=$9`, c.Environment, c.Source, c.Epoch, c.Route.Channel, c.Route.Environment, c.Route.Merchant, c.Route.App, string(facts), c.SourceSystem).Scan(&origin)
	return origin, err
}

/** paymentBasis 保持数字精度和固定字段顺序，用于读取已保存的证明。 */
func paymentBasis(notice *payment.CashNotice, origin []byte) ([]byte, error) {
	var stableOrigin map[string]any
	reader := json.NewDecoder(bytes.NewReader(origin))
	reader.UseNumber()
	if reader.Decode(&stableOrigin) != nil || stableOrigin == nil {
		return nil, service.ErrMetonClosed
	}
	return json.Marshal(struct {
		Notice *payment.CashNotice `json:"notice"`
		Origin map[string]any      `json:"origin"`
	}{notice, stableOrigin})
}

/** refundOrderBasis 先到的通知和稍后找到原退款的重投认同一原商户订单，旧完整摘要仅用于识别已经保存的历史证明。 */
func refundOrderBasis(notice *payment.CashNotice, origin []byte) ([]byte, []byte, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(origin, &fields) != nil || fields == nil {
		return nil, nil, service.ErrMetonClosed
	}
	if _, bound := fields["refund"]; !bound {
		return origin, nil, nil
	}
	legacy, err := paymentBasis(notice, origin)
	if err != nil {
		return nil, nil, err
	}
	for _, field := range []string{"payment", "part", "refund", "refundIntent", "refundOrder", "basis", "requestedFen", "requestedUnits"} {
		delete(fields, field)
	}
	raw, err := json.Marshal(fields)
	hash := sha256.Sum256(legacy)
	return raw, hash[:], err
}

/** sealPaymentProof 保留签名原文与受控查询目标，各取自己的证据种类；两者都使用冻结原单来计算经济内容摘要。 */
func (s *cashNoticeStore) sealPaymentProof(kind, reference string, notice *payment.CashNotice, origin, raw []byte, headers http.Header, publicKey, queryTarget string) ([]byte, []byte, error) {
	c := s.cfg
	basis, err := paymentBasis(notice, origin)
	if err != nil {
		return nil, nil, service.ErrMetonClosed
	}
	digest := sha256.Sum256(basis)
	proof, err := json.Marshal(struct {
		Version     int             `json:"version"`
		Basis       json.RawMessage `json:"basis"`
		Raw         []byte          `json:"raw"`
		Headers     http.Header     `json:"signatureHeaders"`
		PublicKey   string          `json:"platformPublicKey"`
		Callback    string          `json:"callback"`
		Writer      json.RawMessage `json:"writer"`
		QueryTarget string          `json:"queryTarget,omitempty"`
	}{1, basis, raw, headers, publicKey, c.Callback, s.wire, queryTarget})
	if err != nil {
		return nil, nil, service.ErrMetonClosed
	}
	aad, err := cashNoticeAAD(c, kind, reference, c.KeyRef, digest[:])
	if err != nil {
		return nil, nil, service.ErrMetonClosed
	}
	nonce := make([]byte, s.cipher.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return nil, nil, service.ErrMetonClosed
	}
	return digest[:], s.cipher.Seal(nonce, nonce, proof, aad), nil
}
