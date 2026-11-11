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

type cashArchiveStore struct {
	db      *sql.DB
	source  *sql.DB
	control *sql.DB
	review  *cashManualReviewStore
	route   json.RawMessage
}

/** 用当前配置的独立归档身份执行只读事务；SQL 每次核对商户范围和当前权威，没有原库备用连接。 */
func (s *cashArchiveStore) ReadCashArchive(ctx context.Context, q service.CashArchiveRequest) (json.RawMessage, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var result []byte
	if q.OriginalKey == nil {
		err = tx.QueryRowContext(ctx, "SELECT meton_inbox.read_cash_archive_operations($1,$2,$3)", string(s.route), q.After, q.Size).Scan(&result)
	} else {
		err = tx.QueryRowContext(ctx, "SELECT meton_inbox.read_cash_archive_operation($1,$2)", string(s.route), *q.OriginalKey).Scan(&result)
	}
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}

type cashArchiveConfiguration struct {
	ManualReview      *cashManualReviewConfiguration `json:"manual_review,omitempty"`
	RetryDSNFile      string                         `json:"retry_dsn_file,omitempty"`
	FormatVersion     int                            `json:"format_version"`
	Identity          service.CashArchiveIdentity    `json:"identity"`
	Route             json.RawMessage                `json:"route"`
	ReadDSNFile       string                         `json:"read_dsn_file"`
	SourceReadDSNFile string                         `json:"source_read_dsn_file,omitempty"`
}

/** 只在显式配置时打开；首次只读核验当前角色、独立数据库和固定范围，失败释放本次池。 */
func OpenCashArchive(path string) (*service.MetonCashArchive, func(), error) {
	if path == "" {
		return nil, func() {}, nil
	}
	raw, err := readFile("", path, 32768)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg cashArchiveConfiguration
	source, ok := service.MetonSource()
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || cfg.ReadDSNFile == "" || len(cfg.Route) == 0 {
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
	var sourceDB, controlDB *sql.DB
	closeReview := func() {}
	close := func() {
		closeReview()
		_ = db.Close()
		if controlDB != nil {
			_ = controlDB.Close()
		}
		if sourceDB != nil {
			_ = sourceDB.Close()
		}
	}
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	// 来源池必须沿原只读身份复验；未配置时原归档列表仍可用，关联入口明确关闭。
	if cfg.SourceReadDSNFile != "" {
		material, e := readFile(filepath.Dir(path), cfg.SourceReadDSNFile, 32768)
		if e != nil {
			close()
			return nil, func() {}, e
		}
		sourceDB, e = sql.Open("postgres", strings.TrimSpace(string(material)))
		if e != nil {
			close()
			return nil, func() {}, service.ErrMetonClosed
		}
		sourceDB.SetMaxOpenConns(8)
		sourceDB.SetMaxIdleConns(2)
		sourceDB.SetConnMaxLifetime(5 * time.Minute)
		if _, e = NewCashOperations(sourceDB); e != nil {
			close()
			return nil, func() {}, e
		}
	}
	if cfg.RetryDSNFile != "" {
		if _, enabled := source.CashOriginalRetryKeyID(); !enabled {
			close()
			return nil, func() {}, service.ErrMetonClosed
		}
		material, e := readFile(filepath.Dir(path), cfg.RetryDSNFile, 32768)
		if e != nil {
			close()
			return nil, func() {}, e
		}
		controlDB, e = sql.Open("postgres", strings.TrimSpace(string(material)))
		if e != nil {
			close()
			return nil, func() {}, service.ErrMetonClosed
		}
		controlDB.SetMaxOpenConns(8)
		controlDB.SetMaxIdleConns(2)
		controlDB.SetConnMaxLifetime(5 * time.Minute)
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		var ready bool
		e = controlDB.QueryRowContext(ctx, "SELECT meton_inbox.cash_original_retry_ready($1)", string(cfg.Route)).Scan(&ready)
		cancel()
		if e != nil || !ready {
			close()
			return nil, func() {}, service.ErrMetonClosed
		}
	}
	review, reviewClose, err := openCashManualReview(filepath.Dir(path), cfg.ManualReview, cfg.Route, source)
	if err != nil {
		close()
		return nil, func() {}, err
	}
	closeReview = reviewClose
	query := service.NewMetonCashArchive(&cashArchiveStore{db: db, source: sourceDB, control: controlDB, review: review, route: cfg.Route}, cfg.Identity)
	if query == nil {
		close()
		return nil, func() {}, service.ErrMetonClosed
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	_, err = query.Read(ctx, source, service.CashArchiveRequest{Version: 1, Environment: cfg.Identity.Environment, Source: cfg.Identity.Source, Epoch: cfg.Identity.Epoch, ScopeKey: cfg.Identity.ScopeKey, Size: 1})
	if err != nil {
		close()
		return nil, func() {}, err
	}
	if sourceDB != nil {
		key := "refund/00000000-0000-0000-0000-000000000001"
		_, err = query.ReadOriginal(ctx, source, service.CashArchiveRequest{Version: 1, Environment: cfg.Identity.Environment,
			Source: cfg.Identity.Source, Epoch: cfg.Identity.Epoch, ScopeKey: cfg.Identity.ScopeKey, Size: 1, OriginalKey: &key})
		if err != nil {
			close()
			return nil, func() {}, err
		}
	}
	return query, close, nil
}
