//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

const financialTypes = "(text,text,bigint,text,bigint,timestamptz,bigint,text)"
const FinancialReadFunction = "meton_ledger.http_read_financial_observation" + financialTypes
const FinancialCheckFunction = "meton_ledger.check_http_financial_observation" + financialTypes

type financialStore struct{ db *sql.DB }

/** 每次新建只读事务；实际查询期限在 SQL 开始前设置，不在查询内部假装限时。 */
func (s *financialStore) query(ctx context.Context, scope metonmodel.FinancialScope, a metonmodel.FinancialAccess, observe bool) (json.RawMessage, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL statement_timeout='3s'"); err != nil {
		return nil, err
	}
	args := []any{scope.Environment, scope.Source, scope.Epoch, a.KeyID, a.CreatorID, a.Revision, a.Until.UnixMilli(), a.Witness}
	var raw []byte
	if observe {
		err = tx.QueryRowContext(ctx, "SELECT meton_ledger.http_read_financial_observation($1,$2,$3,$4,$5,$6,$7,$8)", args...).Scan(&raw)
	} else {
		var ok bool
		err = tx.QueryRowContext(ctx, "SELECT meton_ledger.check_http_financial_observation($1,$2,$3,$4,$5,$6,$7,$8)", args...).Scan(&ok)
		if err == nil && !ok {
			err = service.ErrMetonClosed
		}
	}
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return raw, nil
}
func (s *financialStore) Read(ctx context.Context, scope metonmodel.FinancialScope, a metonmodel.FinancialAccess) (json.RawMessage, error) {
	return s.query(ctx, scope, a, true)
}
func (s *financialStore) Confirm(ctx context.Context, scope metonmodel.FinancialScope, a metonmodel.FinancialAccess) error {
	_, err := s.query(ctx, scope, a, false)
	return err
}

type financialConfiguration struct {
	FormatVersion int    `json:"format_version"`
	Environment   string `json:"environment"`
	Source        string `json:"source"`
	Epoch         int64  `json:"epoch"`
	DSNFile       string `json:"dsn_file"`
	Parallel      int    `json:"parallel"`
	TimeoutMS     int    `json:"timeout_ms"`
	HistoryFile   string `json:"recovery_keys_file,omitempty"`
	HistoryHash   string `json:"recovery_keys_sha256,omitempty"`
}

/** 默认关闭，只接受显式的专用角色；配置错误不能回退到来源管理员或资金池。 */
func OpenFinancialControl(path string) (*service.MetonFinancialControl, func(), error) {
	empty := func() {}
	if path == "" {
		return nil, empty, nil
	}
	raw, err := readFile("", path, 65536)
	if err != nil {
		return nil, empty, service.ErrMetonClosed
	}
	var cfg financialConfiguration
	source, ok := service.MetonSource()
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || cfg.Environment != source.Environment || cfg.Source != source.Source || cfg.Epoch != source.Epoch || cfg.Parallel < 1 || cfg.Parallel > 4 || cfg.TimeoutMS < 1 || cfg.TimeoutMS > 5000 {
		return nil, empty, service.ErrMetonClosed
	}
	var history *service.FinancialKeyHistory
	if cfg.Epoch > 1 || cfg.HistoryFile != "" || cfg.HistoryHash != "" {
		if cfg.HistoryFile == "" || len(cfg.HistoryHash) != 64 {
			return nil, empty, service.ErrMetonClosed
		}
		material, e := readFile(filepath.Dir(path), cfg.HistoryFile, 262144)
		sum := sha256.Sum256(material)
		history = &service.FinancialKeyHistory{}
		if e != nil || hex.EncodeToString(sum[:]) != cfg.HistoryHash || metonexecution.DecodeStrict(material, history) != nil {
			return nil, empty, service.ErrMetonClosed
		}
	}
	secret, err := readFile(filepath.Dir(path), cfg.DSNFile, 32768)
	if err != nil {
		return nil, empty, service.ErrMetonClosed
	}
	db, err := sql.Open("postgres", strings.TrimSpace(string(secret)))
	if err != nil {
		return nil, empty, service.ErrMetonClosed
	}
	db.SetMaxOpenConns(cfg.Parallel)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)
	var once sync.Once
	closePool := func() { once.Do(func() { _ = db.Close() }) }
	if _, _, err = checkPoolPermissions(db, []string{FinancialReadFunction, FinancialCheckFunction}); err != nil || !giftPoolSeparate(db) || !resultPoolPrivate(db) {
		closePool()
		return nil, empty, service.ErrMetonClosed
	}
	control, err := service.NewMetonFinancialControl(source, &financialStore{db}, cfg.Parallel, time.Duration(cfg.TimeoutMS)*time.Millisecond, history)
	if err != nil {
		closePool()
		return nil, empty, service.ErrMetonClosed
	}
	return control, closePool, nil
}
