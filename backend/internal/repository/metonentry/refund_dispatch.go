//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type refundWorkerConfig struct {
	Version    int    `json:"format_version"`
	SourceDSN  string `json:"source_dsn_file"`
	ArchiveDSN string `json:"archive_dsn_file"`
}

var refundSourceFunctions = []string{"meton_ledger.notification_system_id()", "meton_ledger.refund_dispatch_ready(jsonb)",
	"meton_ledger.claim_original_refund_work(jsonb)", "meton_ledger.mark_original_refund_dispatch(jsonb,uuid,uuid,jsonb)",
	"meton_ledger.original_refund_io_permit(jsonb,uuid,uuid,jsonb)", "meton_ledger.finish_original_refund_work(jsonb,uuid,uuid,text)",
	"meton_ledger.claim_recovered_refund_query(jsonb)", "meton_ledger.finish_recovered_refund_query(jsonb,uuid,uuid,text)"}
var refundArchiveFunctions = []string{"meton_inbox.refund_dispatch_ready(jsonb)", "meton_inbox.bind_original_refund_dispatch(jsonb,jsonb,text,jsonb,text,text)",
	"meton_inbox.start_bound_refund_io(jsonb,uuid,uuid,text,text)", "meton_inbox.hold_bound_refund_io(jsonb,uuid,uuid,text)",
	"meton_inbox.retire_original_refund_sender(jsonb,uuid,uuid,text)", "meton_inbox.retire_elapsed_refund_sender(jsonb,uuid,uuid)",
	"meton_inbox.record_original_refund_transport(jsonb,uuid,text,text,bytea,bytea,jsonb,text,bytea)",
	"meton_inbox.authorize_recovered_refund_lookup(jsonb,jsonb,text)", "meton_inbox.record_recovered_refund_get(jsonb,uuid,text,bytea,bytea,jsonb,text,bytea,text)",
	"meton_inbox.begin_alternative_cash(jsonb,jsonb)", "meton_inbox.hold_alternative_cash(jsonb,text)", "meton_inbox.record_alternative_cash(jsonb,text,jsonb,bytea,text,bytea)"}

type refundChannel interface {
	SendOriginalRefund(context.Context, payment.OriginalRefundTarget) (*payment.CashQueryProof, error)
	QueryOriginalRefund(context.Context, payment.OriginalRefundTarget) (*payment.CashQueryProof, error)
}
type refundDispatcher struct {
	source, archive *sql.DB
	receiver        *cashNoticeStore
	channel         refundChannel
}
type refundGrantMaterial struct {
	Scope       json.RawMessage
	Target      json.RawMessage
	OriginProof string
}
type refundJob struct {
	Mode                  string
	Refund, Intent, Lease uuid.UUID
	Owner, Envelope       json.RawMessage
	Material              refundGrantMaterial
	WireMac               string
	Lookup                string
}
type refundEnvelope struct {
	Cash                  payment.OriginalRefundTarget
	SendUntil, QueryUntil time.Time
}
type refundBind struct {
	State string
	Gate  json.RawMessage
}
type boundGate struct {
	Granted    bool
	SendSecret string
	Facts      struct {
		Ticket uuid.UUID
		Choice string
	}
	MAC string
}

/** StartOriginalRefundDelivery 只装配已登记的本机模拟路由。来源和截点外各用专用角色，失败时关闭整个可选组件。 */
func StartOriginalRefundDelivery(path string, notices *service.MetonCashNotifications) (func(), error) {
	if path == "" {
		return func() {}, nil
	}
	if notices == nil || !notices.Route.Valid() {
		return nil, service.ErrMetonClosed
	}
	n, ok := notices.Store.(*cashNoticeStore)
	if !ok {
		return nil, service.ErrMetonClosed
	}
	source, archive, closePools, err := openRefundDatabases(path)
	if err != nil {
		return nil, err
	}
	w := &refundDispatcher{receiver: n, channel: notices, source: source, archive: archive}
	check, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, sourceRole, e := checkPoolPermissions(w.source, refundSourceFunctions)
	archiveSystem, archiveRole, ae := checkCashArchive(check, w.archive, refundArchiveFunctions)
	var primary string
	var sourceReady, archiveReady bool
	if e != nil || ae != nil || sourceRole == archiveRole || archiveSystem != n.cfg.InboxSystem || !giftPoolSeparate(w.source) || !resultPoolPrivate(w.source) ||
		w.source.QueryRowContext(check, "SELECT meton_ledger.notification_system_id(),meton_ledger.refund_dispatch_ready($1)", string(n.wire)).Scan(&primary, &sourceReady) != nil ||
		primary != n.cfg.SourceSystem || !sourceReady || w.archive.QueryRowContext(check, "SELECT meton_inbox.refund_dispatch_ready($1)", string(n.wire)).Scan(&archiveReady) != nil || !archiveReady {
		closePools()
		return nil, service.ErrMetonClosed
	}
	ctx, stop := context.WithCancel(context.Background())
	var group sync.WaitGroup
	group.Add(2)
	go func() { defer group.Done(); runCashWorker(ctx, w.next) }()
	go func() { defer group.Done(); runCashWorker(ctx, w.recoveredNext) }()
	return func() { stop(); group.Wait(); closePools() }, nil
}

/** archiveTx 开始实际网络请求前和交付可用回执前都须确认上一笔独立事务已提交。 */
func (w *refundDispatcher) archiveTx(ctx context.Context, fn func(*sql.Tx) error) error {
	return withRefundArchive(ctx, w.archive, fn)
}

/** openRefundDatabases 派发与结清采用相同的连接约束，各自的调用者再核对专属角色和准许的函数。 */
func openRefundDatabases(path string) (*sql.DB, *sql.DB, func(), error) {
	var cfg refundWorkerConfig
	raw, err := readFile("", path, 32768)
	if err != nil || metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.Version != 1 || cfg.SourceDSN == "" || cfg.ArchiveDSN == "" || cfg.SourceDSN == cfg.ArchiveDSN {
		return nil, nil, nil, service.ErrMetonClosed
	}
	open := func(file string) (*sql.DB, error) {
		v, err := readFile(filepath.Dir(path), file, 32768)
		if err != nil {
			return nil, err
		}
		pool, err := sql.Open("postgres", strings.TrimSpace(string(v)))
		if err != nil {
			return nil, err
		}
		pool.SetMaxOpenConns(4)
		pool.SetMaxIdleConns(1)
		pool.SetConnMaxLifetime(5 * time.Minute)
		return pool, nil
	}
	source, err := open(cfg.SourceDSN)
	if err != nil {
		return nil, nil, nil, service.ErrMetonClosed
	}
	archive, err := open(cfg.ArchiveDSN)
	if err != nil {
		source.Close()
		return nil, nil, nil, service.ErrMetonClosed
	}
	return source, archive, func() { source.Close(); archive.Close() }, nil
}

/** withRefundArchive 仅在归档提交成功后确认结果，取消或断线时放弃当前事务。 */
func withRefundArchive(ctx context.Context, db *sql.DB, fn func(*sql.Tx) error) error {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return err
	}
	if err = fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

/** bind 核对原归档的签名目标；只有首次成功提交的领取者得到新的发送秘密。 */
func (w *refundDispatcher) bind(ctx context.Context, j *refundJob) (refundBind, boundGate, error) {
	var b refundBind
	var g boundGate
	err := w.archiveTx(ctx, func(tx *sql.Tx) error {
		var raw []byte
		err := tx.QueryRowContext(ctx, "SELECT meton_inbox.bind_original_refund_dispatch($1,$2,$3,$4,$5,$6)", string(j.Material.Scope),
			string(j.Material.Target), j.Material.OriginProof, string(j.Envelope), j.WireMac, j.Mode).Scan(&raw)
		if err != nil {
			return err
		}
		if err = json.Unmarshal(raw, &b); err != nil {
			return err
		}
		if len(b.Gate) > 0 && string(b.Gate) != "null" {
			return json.Unmarshal(b.Gate, &g)
		}
		return nil
	})
	return b, g, err
}

/** next 只消费一份来源领取。失去初次秘密的节点只能按原号查询，即使原来源回到了派发之前。 */
func (w *refundDispatcher) next(ctx context.Context) (bool, error) {
	var job *refundJob
	err := cashSourceResult(ctx, w.source, &job, "SELECT coalesce(meton_ledger.claim_original_refund_work($1),'null'::jsonb)", string(w.receiver.wire))
	if err != nil || job == nil {
		return false, err
	}
	if job.Mode == "review" {
		return true, nil
	}
	var e refundEnvelope
	if (job.Mode != "claim" && job.Mode != "query") || job.Refund == uuid.Nil || job.Lease == uuid.Nil || job.Intent == uuid.Nil || json.Unmarshal(job.Envelope, &e) != nil ||
		e.Cash.Merchant != w.receiver.cfg.Route.Merchant || e.Cash.App != w.receiver.cfg.Route.App || len(job.WireMac) != 64 {
		return true, service.ErrMetonClosed
	}
	state, err := w.process(ctx, job, e)
	if err != nil {
		return true, err
	}
	var saved bool
	err = cashSourceResult(ctx, w.source, &saved, "SELECT to_jsonb(meton_ledger.finish_original_refund_work($1,$2,$3,$4))", string(job.Owner), job.Refund, job.Lease, state)
	if err == nil && !saved {
		err = service.ErrMetonClosed
	}
	return true, err
}

/** process 将归档的已提交决定带回来源，旧票、重复领取和结果未知都转入查询或核对。 */
func (w *refundDispatcher) process(ctx context.Context, j *refundJob, e refundEnvelope) (string, error) {
	b, g, err := w.bind(ctx, j)
	if err != nil {
		return "", err
	}
	switch b.State {
	case "review", "pending":
		return b.State, nil
	case "evidence":
		if g.MAC != "" {
			var phase string
			err = cashSourceResult(ctx, w.source, &phase, "SELECT to_jsonb(meton_ledger.mark_original_refund_dispatch($1,$2,$3,$4))", string(j.Owner), j.Refund, j.Lease, string(b.Gate))
			if err != nil {
				return "", err
			}
			if phase == "review" {
				return phase, nil
			}
		}
		return "evidence", nil
	case "ready":
	default:
		return "", service.ErrMetonClosed
	}
	if g.Facts.Ticket == uuid.Nil {
		return w.query(ctx, j, e)
	}
	// 只有首次独立提交回给本进程的秘密授权一次传输。补查签章从新的事务读取，永远不会重新签发秘密。
	secret := g.SendSecret
	if g.Granted && (j.Mode != "claim" || len(secret) != 64) {
		return "", service.ErrMetonClosed
	}
	if !g.Granted {
		secret = ""
	}
	if secret != "" || g.MAC == "" {
		previous := g.Facts.Ticket
		b, g, err = w.bind(ctx, j)
		if err != nil {
			return "", err
		}
		if b.State != "ready" || g.Facts.Ticket != previous || g.MAC == "" || g.Granted {
			return "", service.ErrMetonClosed
		}
	}
	if secret == "" && g.Facts.Choice == "claimed" {
		var retired bool
		err = w.archiveTx(ctx, func(tx *sql.Tx) error {
			return tx.QueryRowContext(ctx, "SELECT meton_inbox.retire_elapsed_refund_sender($1,$2,$3)",
				string(j.Material.Scope), j.Refund, g.Facts.Ticket).Scan(&retired)
		})
		if err != nil {
			return "", err
		}
		if retired {
			b, g, err = w.bind(ctx, j)
			if err != nil {
				return "", err
			}
		}
	}
	var phase string
	err = cashSourceResult(ctx, w.source, &phase, "SELECT to_jsonb(meton_ledger.mark_original_refund_dispatch($1,$2,$3,$4))", string(j.Owner), j.Refund, j.Lease, string(b.Gate))
	if err != nil {
		return "", err
	}
	switch phase {
	case "released", "settled":
		return "released", nil
	case "review":
		return "review", nil
	case "possibly_sent", "unknown":
	default:
		return "", service.ErrMetonClosed
	}
	if secret != "" && phase == "possibly_sent" {
		return w.sendOnce(ctx, j, e, g.Facts.Ticket, secret)
	}
	return w.query(ctx, j, e)
}

/** query 的到期时间由原退款给出，当前部署不能为旧单延长查询。 */
func (w *refundDispatcher) query(ctx context.Context, j *refundJob, e refundEnvelope) (string, error) {
	bounded, done := context.WithDeadline(ctx, e.QueryUntil)
	defer done()
	if bounded.Err() != nil {
		return "review", nil
	}
	proof, err := w.channel.QueryOriginalRefund(bounded, e.Cash)
	if err != nil || proof == nil {
		return "unknown", nil
	}
	var state string
	err = w.archiveTx(ctx, func(tx *sql.Tx) error {
		var saveErr error
		state, saveErr = w.save(ctx, tx, j, "GET", proof)
		return saveErr
	})
	return state, err
}

/** sendOnce 在原库已提交可能已发、归档已提交单次启动之后才碰网络。进程失联不会让其他节点取得同一秘密。 */
func (w *refundDispatcher) sendOnce(ctx context.Context, j *refundJob, e refundEnvelope, ticket uuid.UUID, secret string) (string, error) {
	var scope struct{ ValidUntil time.Time }
	if json.Unmarshal(j.Material.Scope, &scope) != nil || scope.ValidUntil.IsZero() {
		return "", service.ErrMetonClosed
	}
	until := scope.ValidUntil
	if e.SendUntil.Before(until) {
		until = e.SendUntil
	}
	var permit *string
	err := cashSourceResult(ctx, w.source, &permit, "SELECT coalesce(to_jsonb(meton_ledger.original_refund_io_permit($1,$2,$3,$4)),'null'::jsonb)",
		string(j.Owner), j.Refund, j.Lease, string(j.Material.Scope))
	if err != nil {
		return "", err
	}
	var ioSecret sql.NullString
	if permit != nil {
		err = w.archiveTx(ctx, func(tx *sql.Tx) error {
			return tx.QueryRowContext(ctx, "SELECT meton_inbox.start_bound_refund_io($1,$2,$3,$4,$5)",
				string(j.Material.Scope), j.Refund, ticket, secret, *permit).Scan(&ioSecret)
		})
		if err != nil {
			return "", err
		}
	}
	state := "unknown"
	if ioSecret.Valid {
		err = w.archiveTx(ctx, func(tx *sql.Tx) error {
			var allowed bool
			if e := tx.QueryRowContext(ctx, "SELECT meton_inbox.hold_bound_refund_io($1,$2,$3,$4)", string(j.Material.Scope), j.Refund, ticket, ioSecret.String).Scan(&allowed); e != nil {
				return e
			}
			if !allowed {
				return nil
			}
			bounded, cancel := context.WithDeadline(ctx, until)
			defer cancel()
			if bounded.Err() != nil {
				return nil
			}
			proof, e2 := w.channel.SendOriginalRefund(bounded, e.Cash)
			if e2 != nil || proof == nil {
				return nil
			}
			var x error
			state, x = w.save(ctx, tx, j, "POST", proof)
			return x
		})
		if err != nil {
			return "", err
		}
	}
	// 真实传输期间锁一直存在。即便签名应答没到，登记过传输的原笔仍保持可能已发。
	err = w.archiveTx(ctx, func(tx *sql.Tx) error {
		var ignored []byte
		return tx.QueryRowContext(ctx, "SELECT meton_inbox.retire_original_refund_sender($1,$2,$3,$4)", string(j.Material.Scope), j.Refund, ticket, secret).Scan(&ignored)
	})
	if err != nil {
		return "", err
	}
	if !ioSecret.Valid {
		b, g, e2 := w.bind(ctx, j)
		if e2 != nil {
			return "", e2
		}
		if g.Facts.Choice == "unsent" && g.MAC != "" {
			var phase string
			if e2 = cashSourceResult(ctx, w.source, &phase, "SELECT to_jsonb(meton_ledger.mark_original_refund_dispatch($1,$2,$3,$4))",
				string(j.Owner), j.Refund, j.Lease, string(b.Gate)); e2 != nil {
				return "", e2
			}
			if phase == "released" {
				return "released", nil
			}
		}
	}
	return state, nil
}
