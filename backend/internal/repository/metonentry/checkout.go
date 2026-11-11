//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
	"github.com/lib/pq"
)

const checkoutParameters = "(text,text,bigint,timestamptz,bigint,text)"

type checkoutConfig struct {
	FormatVersion         int                           `json:"format_version"`
	Environment           string                        `json:"environment"`
	Source                string                        `json:"source"`
	Epoch                 int64                         `json:"epoch"`
	IssueDSN              string                        `json:"issue_dsn_file"`
	RedeemDSN             string                        `json:"redeem_dsn_file"`
	StatusDSN             string                        `json:"status_dsn_file"`
	QuoteDSN              string                        `json:"quote_dsn_file,omitempty"`
	ConfirmDSN            string                        `json:"confirm_dsn_file,omitempty"`
	OrderDSN              string                        `json:"order_dsn_file,omitempty"`
	PresentDSN            string                        `json:"present_dsn_file,omitempty"`
	CancelDSN             string                        `json:"cancel_dsn_file,omitempty"`
	LifecycleDSN          string                        `json:"lifecycle_dsn_file,omitempty"`
	ClosureOpenDSN        string                        `json:"closure_open_dsn_file,omitempty"`
	ClosurePageDSN        string                        `json:"closure_page_dsn_file,omitempty"`
	ClosureBindDSN        string                        `json:"closure_bind_dsn_file,omitempty"`
	ClosureScopeDSN       string                        `json:"closure_scope_dsn_file,omitempty"`
	ClosureRefundAdmitDSN string                        `json:"closure_refund_admit_dsn_file,omitempty"`
	ClosureRefundStopDSN  string                        `json:"closure_refund_stop_dsn_file,omitempty"`
	ClosureRefundsDSN     string                        `json:"closure_refunds_dsn_file,omitempty"`
	ClosureSourceSystem   string                        `json:"closure_source_system,omitempty"`
	RefundQuoteDSN        string                        `json:"refund_quote_dsn_file,omitempty"`
	RefundQuoteStatusDSN  string                        `json:"refund_quote_status_dsn_file,omitempty"`
	RefundConfirmDSN      string                        `json:"refund_confirm_dsn_file,omitempty"`
	RefundStatusDSN       string                        `json:"refund_status_dsn_file,omitempty"`
	RefundSourceSystem    string                        `json:"refund_source_system,omitempty"`
	RefundCancelDSN       string                        `json:"refund_cancel_dsn_file,omitempty"`
	RefundStopArchiveDSN  string                        `json:"refund_stop_archive_dsn_file,omitempty"`
	RefundStopSystem      string                        `json:"refund_stop_system,omitempty"`
	DisputeSubmitDSN      string                        `json:"dispute_submit_dsn_file,omitempty"`
	DisputeStatusDSN      string                        `json:"dispute_status_dsn_file,omitempty"`
	DisputeArchiveDSN     string                        `json:"dispute_archive_dsn_file,omitempty"`
	DisputeArchiveSystem  string                        `json:"dispute_archive_system,omitempty"`
	DisputeCipherFile     string                        `json:"dispute_cipher_file,omitempty"`
	DisputeCipherRef      string                        `json:"dispute_cipher_ref,omitempty"`
	PaymentRoute          *service.CheckoutPaymentRoute `json:"payment_route,omitempty"`
}
type checkoutPool struct {
	db          *sql.DB
	function    string
	stopArchive *sql.DB
	disputes    *memberDisputeStore
}
type checkoutStore map[string]checkoutPool

/** OpenCheckout 只在装配新能力时打开三种独立角色；缺一项即回收本次已打开的连接。 */
func OpenCheckout(path string) (*service.MetonCheckout, func(), error) {
	noop := func() {}
	if path == "" {
		return nil, noop, nil
	}
	raw, err := readFile("", path, 32768)
	source, valid := service.MetonSource()
	ids, enabled := service.CheckoutKeyIDs()
	var cfg checkoutConfig
	if err != nil || !valid || !enabled || metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 ||
		cfg.Environment != source.Environment || cfg.Source != source.Source || cfg.Epoch != source.Epoch {
		return nil, noop, service.ErrMetonClosed
	}
	store := checkoutStore{}
	closePools := func() {
		for _, p := range store {
			_ = p.db.Close()
			if p.disputes != nil {
				_ = p.disputes.archive.Close()
			}
			if p.stopArchive != nil {
				_ = p.stopArchive.Close()
			}
		}
	}
	roles := map[string]bool{}
	database := ""
	type operation struct{ action, file string }
	operations := []operation{{"issue", cfg.IssueDSN}, {"redeem", cfg.RedeemDSN}, {"status", cfg.StatusDSN}}
	if cfg.QuoteDSN != "" || cfg.ConfirmDSN != "" || cfg.OrderDSN != "" || ids["order"] != "" {
		if cfg.QuoteDSN == "" || cfg.ConfirmDSN == "" || cfg.OrderDSN == "" || ids["order"] == "" {
			return nil, noop, service.ErrMetonClosed
		}
		operations = append(operations, operation{"quote", cfg.QuoteDSN}, operation{"confirm", cfg.ConfirmDSN}, operation{"order", cfg.OrderDSN})
	}
	if cfg.PresentDSN != "" || cfg.PaymentRoute != nil || ids["present"] != "" {
		if cfg.PresentDSN == "" || ids["present"] == "" || cfg.PaymentRoute == nil || !cfg.PaymentRoute.Valid() {
			return nil, noop, service.ErrMetonClosed
		}
		operations = append(operations, operation{"present", cfg.PresentDSN})
	}
	if cfg.CancelDSN != "" || ids["cancel"] != "" {
		if cfg.CancelDSN == "" || ids["cancel"] == "" || ids["order"] == "" {
			return nil, noop, service.ErrMetonClosed
		}
		operations = append(operations, operation{"cancel", cfg.CancelDSN})
	}
	if cfg.LifecycleDSN != "" || ids["lifecycle"] != "" {
		if cfg.LifecycleDSN == "" || ids["lifecycle"] == "" || ids["order"] == "" {
			return nil, noop, service.ErrMetonClosed
		}
		operations = append(operations, operation{"lifecycle", cfg.LifecycleDSN})
	}
	if ids["refund_quote"] != "" || cfg.RefundSourceSystem != "" || cfg.RefundQuoteDSN != "" || cfg.RefundQuoteStatusDSN != "" || cfg.RefundConfirmDSN != "" || cfg.RefundStatusDSN != "" {
		if cfg.LifecycleDSN == "" || !pgSystemNumber.MatchString(cfg.RefundSourceSystem) {
			return nil, noop, service.ErrMetonClosed
		}
		for _, ref := range []operation{{"refund_quote", cfg.RefundQuoteDSN}, {"refund_quote_status", cfg.RefundQuoteStatusDSN}, {"refund_confirm", cfg.RefundConfirmDSN}, {"refund_status", cfg.RefundStatusDSN}} {
			if ref.file == "" || ids[ref.action] == "" {
				return nil, noop, service.ErrMetonClosed
			}
			operations = append(operations, ref)
		}
	}
	if ids["refund_cancel"] != "" || cfg.RefundCancelDSN != "" || cfg.RefundStopArchiveDSN != "" || cfg.RefundStopSystem != "" {
		if ids["refund_status"] == "" || ids["refund_cancel"] == "" || cfg.RefundCancelDSN == "" || cfg.RefundStopArchiveDSN == "" ||
			!pgSystemNumber.MatchString(cfg.RefundStopSystem) || cfg.RefundStopSystem == cfg.RefundSourceSystem {
			return nil, noop, service.ErrMetonClosed
		}
		operations = append(operations, operation{"refund_cancel", cfg.RefundCancelDSN})
	}
	if ids["dispute_submit"] != "" || cfg.DisputeSubmitDSN != "" || cfg.DisputeStatusDSN != "" || cfg.DisputeArchiveDSN != "" || cfg.DisputeArchiveSystem != "" || cfg.DisputeCipherFile != "" || cfg.DisputeCipherRef != "" {
		if cfg.LifecycleDSN == "" || !pgSystemNumber.MatchString(cfg.RefundSourceSystem) || !pgSystemNumber.MatchString(cfg.DisputeArchiveSystem) || cfg.DisputeArchiveSystem == cfg.RefundSourceSystem || cfg.DisputeArchiveDSN == "" || cfg.DisputeCipherFile == "" || !noticeKeyRef.MatchString(cfg.DisputeCipherRef) {
			return nil, noop, service.ErrMetonClosed
		}
		for _, ref := range []operation{{"dispute_submit", cfg.DisputeSubmitDSN}, {"dispute_status", cfg.DisputeStatusDSN}} {
			if ref.file == "" || ids[ref.action] == "" {
				return nil, noop, service.ErrMetonClosed
			}
			operations = append(operations, ref)
		}
	}
	if ids["closure_open"] != "" || cfg.ClosureOpenDSN != "" || cfg.ClosurePageDSN != "" || cfg.ClosureSourceSystem != "" {
		if cfg.LifecycleDSN == "" || !pgSystemNumber.MatchString(cfg.ClosureSourceSystem) {
			return nil, noop, service.ErrMetonClosed
		}
		for _, ref := range []operation{{"closure_open", cfg.ClosureOpenDSN}, {"closure_page", cfg.ClosurePageDSN}} {
			if ref.file == "" || ids[ref.action] == "" {
				return nil, noop, service.ErrMetonClosed
			}
			operations = append(operations, ref)
		}
	}
	if ids["closure_bind"] != "" || ids["closure_scope"] != "" || cfg.ClosureBindDSN != "" || cfg.ClosureScopeDSN != "" {
		if cfg.ClosureOpenDSN == "" || cfg.LifecycleDSN == "" || !pgSystemNumber.MatchString(cfg.ClosureSourceSystem) {
			return nil, noop, service.ErrMetonClosed
		}
		for _, ref := range []operation{{"closure_bind", cfg.ClosureBindDSN}, {"closure_scope", cfg.ClosureScopeDSN}} {
			if ref.file == "" || ids[ref.action] == "" {
				return nil, noop, service.ErrMetonClosed
			}
			operations = append(operations, ref)
		}
	}
	if ids["closure_refund_admit"] != "" || ids["closure_refund_stop"] != "" || ids["closure_refunds"] != "" || cfg.ClosureRefundAdmitDSN != "" || cfg.ClosureRefundStopDSN != "" || cfg.ClosureRefundsDSN != "" {
		if cfg.ClosureBindDSN == "" || cfg.ClosureScopeDSN == "" || cfg.LifecycleDSN == "" || !pgSystemNumber.MatchString(cfg.ClosureSourceSystem) {
			return nil, noop, service.ErrMetonClosed
		}
		for _, ref := range []operation{{"closure_refund_admit", cfg.ClosureRefundAdmitDSN}, {"closure_refund_stop", cfg.ClosureRefundStopDSN}, {"closure_refunds", cfg.ClosureRefundsDSN}} {
			if ref.file == "" || ids[ref.action] == "" {
				return nil, noop, service.ErrMetonClosed
			}
			operations = append(operations, ref)
		}
	}
	for _, item := range operations {
		credential, err := readFile(filepath.Dir(path), item.file, 32768)
		if err != nil {
			closePools()
			return nil, noop, service.ErrMetonClosed
		}
		db, err := sql.Open("postgres", strings.TrimSpace(string(credential)))
		if err != nil {
			closePools()
			return nil, noop, service.ErrMetonClosed
		}
		function := "meton_ledger.http_checkout_" + item.action
		store[item.action] = checkoutPool{db: db, function: function}
		db.SetMaxOpenConns(8)
		db.SetMaxIdleConns(2)
		db.SetConnMaxLifetime(5 * time.Minute)
		permissions := []string{function + checkoutParameters}
		if item.action == "refund_cancel" {
			permissions = append(permissions, refundFinishSignature)
		}
		if item.action == "present" {
			permissions = append(permissions, "meton_ledger.save_checkout_presentation(jsonb,uuid,uuid,text,text)")
		}
		if service.IsCheckoutRefund(item.action) || service.IsCheckoutDispute(item.action) || service.IsCheckoutClosure(item.action) || service.IsCheckoutClosureScope(item.action) || service.IsCheckoutClosureRefund(item.action) {
			permissions = append(permissions, "meton_ledger.notification_system_id()")
			expectedSystem := cfg.RefundSourceSystem
			if service.IsCheckoutClosure(item.action) || service.IsCheckoutClosureScope(item.action) || service.IsCheckoutClosureRefund(item.action) {
				expectedSystem = cfg.ClosureSourceSystem
			}
			var system string
			check, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			readErr := db.QueryRowContext(check, "SELECT meton_ledger.notification_system_id()").Scan(&system)
			cancel()
			if readErr != nil || system != expectedSystem {
				closePools()
				return nil, noop, service.ErrMetonClosed
			}
		}
		identity, role, err := checkPoolPermissions(db, permissions)
		if err != nil || roles[role] || database != "" && database != identity || !giftPoolSeparate(db) || !resultPoolPrivate(db) {
			closePools()
			return nil, noop, service.ErrMetonClosed
		}
		roles[role] = true
		database = identity
	}
	if pool, ok := store["refund_cancel"]; ok {
		archive, err := openRefundStopArchive(filepath.Dir(path), cfg, roles)
		if err != nil {
			closePools()
			return nil, noop, err
		}
		pool.stopArchive = archive
		store["refund_cancel"] = pool
	}
	if _, ok := store["dispute_submit"]; ok {
		disputes, err := openMemberDispute(filepath.Dir(path), cfg, roles)
		if err != nil {
			closePools()
			return nil, noop, err
		}
		for _, action := range []string{"dispute_submit", "dispute_status"} {
			pool := store[action]
			pool.disputes = disputes
			store[action] = pool
		}
	}
	return &service.MetonCheckout{Source: source, Keys: ids, Store: store, Route: cfg.PaymentRoute}, closePools, nil
}

/** Checkout 使用启动时固定的入口。出现通信或提交错误只报未知，绝不换池补写。 */
func (s checkoutStore) Checkout(ctx context.Context, action string, wire []byte, a service.CheckoutAccess) (string, error) {
	pool, ok := s[action]
	if !ok {
		return "", service.ErrCheckoutDenied
	}
	ctx, cancel := context.WithDeadline(ctx, time.UnixMilli(a.UntilMS))
	defer cancel()
	tx, err := pool.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: service.CheckoutReadAction(action)})
	if err != nil {
		return "", service.ErrMetonClosed
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL statement_timeout = '4s'"); err != nil {
		return "", service.ErrMetonClosed
	}
	if (service.IsCheckoutRefund(action) || service.IsCheckoutDispute(action) || service.IsCheckoutClosure(action) || service.IsCheckoutClosureRefund(action)) && !service.CheckoutReadAction(action) {
		if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
			return "", service.ErrMetonClosed
		}
	}
	var state sql.NullString
	err = tx.QueryRowContext(ctx, "SELECT "+pool.function+"($1,$2,$3,$4,$5,$6)", string(wire), a.Key, a.Creator, a.Revision, a.UntilMS, a.Witness).Scan(&state)
	if err == nil && state.Valid && service.IsCheckoutDispute(action) {
		state.String, err = pool.disputes.apply(ctx, tx, pool.function, state.String, action, wire, a)
	}
	if err == nil && action == "refund_cancel" {
		state.String, err = pool.finishRefundStop(ctx, tx, state.String, wire, a)
	}
	if err != nil {
		var pg *pq.Error
		if errors.As(err, &pg) {
			switch pg.Code {
			case "23505":
				return "", service.ErrCheckoutConflict
			case "42501", "22023":
				return "", service.ErrCheckoutDenied
			}
		}
		return "", service.ErrMetonClosed
	}
	if tx.Commit() != nil {
		return "", service.ErrMetonClosed
	}
	return state.String, nil
}

/** ObserveCheckoutPayment 只允许原认领角色记录支付呈现。数据库按派发票据和原来源确认，不能修改额度或现金事实。 */
func (s checkoutStore) ObserveCheckoutPayment(ctx context.Context, o service.CheckoutOrigin, intent, dispatch uuid.UUID, kind, value string) error {
	p, ok := s["present"]
	if !ok {
		return service.ErrCheckoutDenied
	}
	raw, err := json.Marshal(o)
	if err != nil {
		return service.ErrMetonClosed
	}
	var saved bool
	err = p.db.QueryRowContext(ctx, "SELECT meton_ledger.save_checkout_presentation($1::jsonb,$2,$3,$4,$5)", string(raw), intent, dispatch, kind, value).Scan(&saved)
	if err != nil || !saved {
		return service.ErrMetonClosed
	}
	return nil
}
