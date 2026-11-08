//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

const restoredGiftTypes = "(" + giftScopeSignature + ",bigint,uuid,uuid,uuid,bigint,bigint,text,bigint,timestamptz,bigint,text)"
const RestoredGiftReadFunction = "meton_ledger.http_find_restored_gift_termination" + restoredGiftTypes
const RestoredGiftReconcileFunction = "meton_ledger.http_reconcile_restored_gift_termination" + restoredGiftTypes
const RestoredGiftTerminateFunction = "meton_ledger.http_terminate_restored_gift" + restoredGiftTypes

type restoredGiftStore struct {
	read, write              *sql.DB
	database, reader, writer string
	terminate                *sql.DB
	terminator               string
}

/** 两池仅有各自的 HTTP 包装函数权限，不具备裸账本或原生身份管理写权。 */
func NewRestoredGiftControl(source service.MetonManagedSource, read, write *sql.DB, parallel int, timeout time.Duration, history *service.RestoredGiftKeyHistory, terminate ...*sql.DB) (*service.MetonRestoredGiftControl, error) {
	if read == nil || write == nil || read == write {
		return nil, service.ErrMetonClosed
	}
	identity, reader, err := checkPool(read, RestoredGiftReadFunction)
	other, writer, e := checkPool(write, RestoredGiftReconcileFunction)
	if err != nil || e != nil || identity != other || reader == writer || !giftPoolSeparate(read) || !giftPoolSeparate(write) || !resultPoolPrivate(read) || !resultPoolPrivate(write) {
		return nil, service.ErrMetonClosed
	}
	store := &restoredGiftStore{read: read, write: write, database: identity, reader: reader, writer: writer}
	if len(terminate) > 1 || (len(terminate) == 1) != (os.Getenv("METON_MANAGED_RESTORED_GIFT_TERMINATE_KEY_ID") != "") {
		return nil, service.ErrMetonClosed
	}
	if len(terminate) == 1 {
		pool := terminate[0]
		if pool == nil || pool == read || pool == write {
			return nil, service.ErrMetonClosed
		}
		other, role, e := checkPool(pool, RestoredGiftTerminateFunction)
		if e != nil || other != identity || role == reader || role == writer || !giftPoolSeparate(pool) || !resultPoolPrivate(pool) {
			return nil, service.ErrMetonClosed
		}
		store.terminate, store.terminator = pool, role
	}
	return service.NewMetonRestoredGiftControl(source, store, parallel, timeout, history)
}

/** 每次只执行固定用途的一个原事务，提交失败不重发；完成后复验实例和当前配置。 */
func (s *restoredGiftStore) Resolve(ctx context.Context, source service.MetonManagedSource, action string, q service.MetonRestoredGiftRequest, a service.MetonRestoredGiftAccess, guard func() bool) (json.RawMessage, error) {
	if guard == nil || !guard() {
		return nil, service.ErrMetonClosed
	}
	db, fn, role := s.read, RestoredGiftReadFunction, s.reader
	if action == "reconcile" {
		db, fn, role = s.write, RestoredGiftReconcileFunction, s.writer
	} else if action == "terminate" && s.terminate != nil {
		db, fn, role = s.terminate, RestoredGiftTerminateFunction, s.terminator
	} else if action != "inspect" {
		return nil, service.ErrMetonClosed
	}
	identity, actual, err := checkPool(db, fn)
	if err != nil || identity != s.database || actual != role || !giftPoolSeparate(db) || !resultPoolPrivate(db) || !guard() {
		return nil, service.ErrMetonClosed
	}
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	ms := time.Until(a.Until).Milliseconds()
	if ms < 1 || ms > 30000 {
		return nil, service.ErrMetonClosed
	}
	if _, err = tx.ExecContext(ctx, "SELECT set_config('statement_timeout',$1,true)", strconv.FormatInt(ms, 10)+"ms"); err != nil {
		return nil, err
	}
	o, f := q.Original.Scope, q.Original.Final
	params := []any{o.Environment, o.Source, source.Epoch, o.User, o.Account, o.Operation, o.Dispatch, o.RemoteUser, o.SourceMarker, o.Eligibility,
		o.Epoch, f.Decision, f.Registration, f.IdentityEvent, f.SecurityVersion, f.IdentityEpoch, a.KeyID, a.CreatorID, a.Revision, a.Until.UnixMilli(), a.Witness}
	name := strings.Split(fn, "(")[0]
	query := "WITH s AS MATERIALIZED(SELECT " + name + "($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21) AS v) SELECT (v-'effects')||jsonb_build_object('effect_count',jsonb_array_length(v->'effects')) FROM s"
	var raw []byte
	if err = tx.QueryRowContext(ctx, query, params...).Scan(&raw); err != nil {
		return nil, err
	}
	if !guard() {
		return nil, service.ErrMetonClosed
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	if !guard() {
		return nil, service.ErrMetonClosed
	}
	return raw, nil
}

type restoredGiftConfiguration struct {
	FormatVersion    int    `json:"format_version"`
	Environment      string `json:"environment"`
	Source           string `json:"source"`
	Epoch            int64  `json:"epoch"`
	ReadDSNFile      string `json:"read_dsn_file"`
	ReconcileDSNFile string `json:"reconcile_dsn_file"`
	TerminateDSNFile string `json:"terminate_dsn_file,omitempty"`
	HistoryFile      string `json:"recovery_keys_file"`
	HistoryHash      string `json:"recovery_keys_sha256"`
	Parallel         int    `json:"parallel"`
	TimeoutMS        int    `json:"timeout_ms"`
}

/** 默认关闭；显式配置必须给出当前公开身份历史和两个独立角色，错误不能降级。 */
func OpenRestoredGiftControl(path string) (*service.MetonRestoredGiftControl, func(), error) {
	empty := func() {}
	if path == "" {
		return nil, empty, nil
	}
	raw, err := readFile("", path, 65536)
	source, ok := service.MetonSource()
	var cfg restoredGiftConfiguration
	if err != nil || metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || cfg.Environment != source.Environment || cfg.Source != source.Source ||
		cfg.Epoch != source.Epoch || cfg.Epoch <= 1 || cfg.Parallel < 1 || cfg.Parallel > 16 || cfg.TimeoutMS < 1 || cfg.TimeoutMS > 30000 || cfg.HistoryFile == "" || len(cfg.HistoryHash) != 64 {
		return nil, empty, service.ErrMetonClosed
	}
	material, e := readFile(filepath.Dir(path), cfg.HistoryFile, 262144)
	digest := sha256.Sum256(material)
	var history service.RestoredGiftKeyHistory
	if e != nil || hex.EncodeToString(digest[:]) != cfg.HistoryHash || metonexecution.DecodeStrict(material, &history) != nil {
		return nil, empty, service.ErrMetonClosed
	}
	pools := make([]*sql.DB, 0, 2)
	var once sync.Once
	closePools := func() {
		once.Do(func() {
			for _, db := range pools {
				_ = db.Close()
			}
		})
	}
	names := []string{cfg.ReadDSNFile, cfg.ReconcileDSNFile}
	if cfg.TerminateDSNFile != "" {
		names = append(names, cfg.TerminateDSNFile)
	}
	for _, name := range names {
		secret, e := readFile(filepath.Dir(path), name, 32768)
		if e != nil {
			closePools()
			return nil, empty, service.ErrMetonClosed
		}
		db, e := sql.Open("postgres", strings.TrimSpace(string(secret)))
		if e != nil {
			closePools()
			return nil, empty, service.ErrMetonClosed
		}
		db.SetMaxOpenConns(cfg.Parallel)
		db.SetMaxIdleConns(1)
		db.SetConnMaxLifetime(5 * time.Minute)
		pools = append(pools, db)
	}
	result, err := NewRestoredGiftControl(source, pools[0], pools[1], cfg.Parallel, time.Duration(cfg.TimeoutMS)*time.Millisecond, &history, pools[2:]...)
	if err != nil {
		closePools()
		return nil, empty, err
	}
	return result, closePools, nil
}
