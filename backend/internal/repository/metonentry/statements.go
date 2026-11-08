//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"path/filepath"
	"strings"
	"time"
)

const statementScope = "text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid"
const StatementOpenFunction = "meton_ledger.open_statement(" + statementScope + ",date,date)"
const StatementPageFunction = "meton_ledger.read_statement_page(" + statementScope + ",date,date,bigint,uuid,bigint,integer)"

type statementStore struct{ read *sql.DB }

/** NewStatements 复用原权限校验，额外禁止读取裸表和兼任会话管理身份。 */
func NewStatements(db *sql.DB) (*service.MetonStatements, error) {
	if _, _, e := checkPoolPermissions(db, []string{StatementOpenFunction, StatementPageFunction}); e != nil {
		return nil, e
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
	return service.NewMetonStatements(&statementStore{db}), nil
}

/** Statement 整条来源读取处于只读事务；分页没有写入后备或跨账户重试。 */
func (s *statementStore) Statement(ctx context.Context, source service.MetonManagedSource, q service.MetonStatementRequest) (json.RawMessage, error) {
	if !source.ValidStatement(q) {
		return nil, service.ErrMetonClosed
	}
	c := q.Scope
	args := []any{c.Environment, c.Source, c.Epoch, c.User, c.Account, c.Operation, c.Dispatch, c.RemoteUser, c.SourceMarker, q.From, q.Through}
	query := "SELECT meton_ledger.open_statement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)"
	if p := q.Page; p != nil {
		args = append(args, p.Sequence, p.Event, p.After, p.Size)
		query = "SELECT meton_ledger.read_statement_page($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)"
	}
	tx, err := s.read.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var raw []byte
	if err = tx.QueryRowContext(ctx, query, args...).Scan(&raw); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return raw, nil
}

type statementConfiguration struct {
	FormatVersion int    `json:"format_version"`
	Environment   string `json:"environment"`
	Source        string `json:"source"`
	Epoch         int64  `json:"epoch"`
	ReadDSNFile   string `json:"read_dsn_file"`
}

/** OpenStatements 独立开关和受限只读池，不修改原生连接、不安装迁移。 */
func OpenStatements(path string) (*service.MetonStatements, func(), error) {
	if path == "" {
		return nil, func() {}, nil
	}
	raw, err := readFile("", path, 32768)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg statementConfiguration
	source, ok := service.MetonSource()
	id, enabled := source.StatementKeyID()
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || !enabled || cfg.Environment != source.Environment || cfg.Source != source.Source || cfg.Epoch != source.Epoch || cfg.ReadDSNFile == "" {
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
	result, err := NewStatements(db)
	if err != nil {
		close()
		return nil, func() {}, err
	}
	now, valid := service.MetonSource()
	key, enabled := source.StatementKeyID()
	if !valid || now != source || !enabled || key != id {
		close()
		return nil, func() {}, service.ErrMetonClosed
	}
	return result, close, nil
}
