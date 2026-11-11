//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

const CashOperationsFunction = "meton_ledger.read_cash_operations(jsonb,text,integer)"

type cashOperationsStore struct{ read *sql.DB }

/** 专用池只有原运营读取函数，不允许把原生全权连接或会员查询连接拿来代用。 */
func NewCashOperations(db *sql.DB) (*service.MetonCashOperations, error) {
	if _, _, err := checkPoolPermissions(db, []string{CashOperationsFunction, "meton_ledger.read_cash_operation(jsonb,text)", "meton_ledger.read_cash_archive_original(jsonb,jsonb)"}); err != nil {
		return nil, err
	}
	if !giftPoolSeparate(db) {
		return nil, service.ErrMetonClosed
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var safe bool
	err := db.QueryRowContext(ctx, `SELECT NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p') AND
 (has_table_privilege(current_user,c.oid,'SELECT') OR has_any_column_privilege(current_user,c.oid,'SELECT')))`).Scan(&safe)
	if err != nil || !safe {
		return nil, service.ErrMetonClosed
	}
	return service.NewMetonCashOperations(&cashOperationsStore{db}), nil
}

func (s *cashOperationsStore) ReadCashOperations(ctx context.Context, source service.MetonManagedSource, q service.CashOperationsRequest) (json.RawMessage, error) {
	if !source.ValidCashOperations(q) {
		return nil, service.ErrMetonClosed
	}
	origin, err := json.Marshal(q.Origin())
	if err != nil {
		return nil, err
	}
	tx, err := s.read.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var raw []byte
	if q.OriginalKey == nil {
		err = tx.QueryRowContext(ctx, "SELECT meton_ledger.read_cash_operations($1,$2,$3)", string(origin), q.After, q.Size).Scan(&raw)
	} else {
		err = tx.QueryRowContext(ctx, "SELECT meton_ledger.read_cash_operation($1,$2)", string(origin), *q.OriginalKey).Scan(&raw)
	}
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return raw, nil
}

type cashOperationsConfiguration struct {
	FormatVersion int    `json:"format_version"`
	Environment   string `json:"environment"`
	Source        string `json:"source"`
	Epoch         int64  `json:"epoch"`
	ReadDSNFile   string `json:"read_dsn_file"`
}

/** 独立显式开关只在监听前装配；缺配置不开放，失败释放本次池，不改变已有服务或安装迁移。 */
func OpenCashOperations(path string) (*service.MetonCashOperations, func(), error) {
	if path == "" {
		return nil, func() {}, nil
	}
	raw, err := readFile("", path, 32768)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg cashOperationsConfiguration
	source, ok := service.MetonSource()
	key, enabled := source.CashOperationsKeyID()
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || !enabled || cfg.Environment != source.Environment ||
		cfg.Source != source.Source || cfg.Epoch != source.Epoch || cfg.ReadDSNFile == "" {
		return nil, func() {}, service.ErrMetonClosed
	}
	secret, err := readFile(filepath.Dir(path), cfg.ReadDSNFile, 32768)
	if err != nil {
		return nil, func() {}, err
	}
	db, err := sql.Open("postgres", strings.TrimSpace(string(secret)))
	if err != nil {
		return nil, func() {}, service.ErrMetonClosed
	}
	close := func() { _ = db.Close() }
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	result, err := NewCashOperations(db)
	if err != nil {
		close()
		return nil, func() {}, err
	}
	live, valid := service.MetonSource()
	current, enabled := source.CashOperationsKeyID()
	if !valid || live != source || !enabled || current != key {
		close()
		return nil, func() {}, service.ErrMetonClosed
	}
	return result, close, nil
}
