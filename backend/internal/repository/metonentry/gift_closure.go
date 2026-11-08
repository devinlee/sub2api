//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/lib/pq"
	"path/filepath"
	"strings"
	"time"
)

const giftScopeSignature = "text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid"
const GiftReadFunction = "meton_ledger.find_gift_termination(" + giftScopeSignature + ")"
const GiftCloseFunction = "meton_ledger.terminate_gift(" + giftScopeSignature + ",uuid,uuid,uuid,bigint,bigint)"
const GiftReconcileFunction = "meton_ledger.reconcile_gift_termination(" + giftScopeSignature + ",uuid)"

type giftClosureStore struct{ read, write *sql.DB }

/** NewGiftClosure 验有效权限、数据库身份及不同角色；多余资金权限也不能借进来。 */
func NewGiftClosure(read, write *sql.DB) (*service.MetonGiftClosure, error) {
	if read == nil || write == nil || read == write {
		return nil, service.ErrMetonClosed
	}
	identity, reader, err := checkPool(read, GiftReadFunction)
	if err != nil {
		return nil, err
	}
	other, writer, err := checkPoolPermissions(write, []string{GiftCloseFunction, GiftReconcileFunction})
	if err != nil || identity != other || reader == writer {
		return nil, service.ErrMetonClosed
	}
	for _, db := range []*sql.DB{read, write} {
		if !giftPoolSeparate(db) {
			return nil, service.ErrMetonClosed
		}
	}
	return service.NewMetonGiftClosure(&giftClosureStore{read, write}), nil
}

/** giftPoolSeparate 资金终止角色不能兼任原账号、会话或恢复写者。 */
func giftPoolSeparate(db *sql.DB) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var separate bool
	err := db.QueryRowContext(ctx, "SELECT NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND (p.proname IN ('meton_claim_managed_account','meton_issue_managed_key','meton_close_original_session','meton_recover_original') OR p.proname LIKE 'meton_retire_key_for_rotation%') AND has_function_privilege(current_user,p.oid,'EXECUTE'))").Scan(&separate)
	return err == nil && separate
}

/** GiftClosure 单语句提交；只读路径不会选择结清池，数据库错误不触发内部重试。 */
func (s *giftClosureStore) GiftClosure(ctx context.Context, source service.MetonManagedSource, action string, q service.MetonGiftRequest) (json.RawMessage, error) {
	if !source.ValidGiftRequest(q, action) {
		return nil, service.ErrMetonClosed
	}
	c := q.Scope
	params := []any{c.Environment, c.Source, c.Epoch, c.User, c.Account, c.Operation, c.Dispatch, c.RemoteUser, c.SourceMarker, c.Eligibility}
	db, name, args := s.read, "meton_ledger.find_gift_termination", "$1,$2,$3,$4,$5,$6,$7,$8,$9,$10"
	if action == "terminate" {
		db, name = s.write, "meton_ledger.terminate_gift"
		f := q.Final
		params = append(params, f.Decision, f.Registration, f.IdentityEvent, f.SecurityVersion, f.IdentityEpoch)
		args += ",$11,$12,$13,$14,$15"
	} else if action == "reconcile" {
		db, name = s.write, "meton_ledger.reconcile_gift_termination"
		params = append(params, q.Final.Decision)
		args += ",$11"
	}
	// 原函数只执行一次；接口只交出效果数量，历史账单由 S2-19 按分页读取。
	query := "WITH s AS MATERIALIZED (SELECT " + name + "(" + args + ") AS v) SELECT (v-'effects')||jsonb_build_object('effect_count',jsonb_array_length(v->'effects')) FROM s"
	var raw []byte
	err := db.QueryRowContext(ctx, query, params...).Scan(&raw)
	var pg *pq.Error
	if errors.As(err, &pg) && pg.Code == "23505" {
		return nil, service.ErrMetonGiftConflict
	}
	return raw, err
}

type giftConfiguration struct {
	FormatVersion int    `json:"format_version"`
	Environment   string `json:"environment"`
	Source        string `json:"source"`
	Epoch         int64  `json:"epoch"`
	ReadDSNFile   string `json:"read_dsn_file"`
	CloseDSNFile  string `json:"close_dsn_file"`
}

/** OpenGiftClosure 独立于模型开关；缺配置保持关闭，显式损坏配置则启动失败。 */
func OpenGiftClosure(path string) (*service.MetonGiftClosure, func(), error) {
	if path == "" {
		return nil, func() {}, nil
	}
	raw, err := readFile("", path, 32768)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg giftConfiguration
	source, ok := service.MetonSource()
	_, enabled := source.GiftClosureKeyID(true)
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || !enabled || cfg.Environment != source.Environment ||
		cfg.Source != source.Source || cfg.Epoch != source.Epoch || cfg.ReadDSNFile == "" || cfg.CloseDSNFile == "" {
		return nil, func() {}, service.ErrMetonClosed
	}
	pools := []*sql.DB{}
	close := func() {
		for _, db := range pools {
			_ = db.Close()
		}
	}
	for _, name := range []string{cfg.ReadDSNFile, cfg.CloseDSNFile} {
		raw, e := readFile(filepath.Dir(path), name, 32768)
		if e != nil {
			close()
			return nil, func() {}, e
		}
		db, e := sql.Open("postgres", strings.TrimSpace(string(raw)))
		if e != nil {
			close()
			return nil, func() {}, service.ErrMetonClosed
		}
		pools = append(pools, db)
		db.SetMaxOpenConns(8)
		db.SetMaxIdleConns(2)
		db.SetConnMaxLifetime(5 * time.Minute)
	}
	result, err := NewGiftClosure(pools[0], pools[1])
	if err != nil {
		close()
		return nil, func() {}, err
	}
	// 配置读取期间代次或受限身份变化，不把旧装配作为已就绪实例。
	if now, valid := service.MetonSource(); !valid || now != source {
		close()
		return nil, func() {}, service.ErrMetonClosed
	}
	if _, valid := source.GiftClosureKeyID(true); !valid {
		close()
		return nil, func() {}, service.ErrMetonClosed
	}
	return result, close, nil
}
