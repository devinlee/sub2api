//go:build meton_managed

package metonentry

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type restoredShortfallConfiguration struct {
	HistoryFile     string `json:"recovery_keys_file,omitempty"`
	HistoryHash     string `json:"recovery_keys_sha256,omitempty"`
	FormatVersion   int    `json:"format_version"`
	Environment     string `json:"environment"`
	Source          string `json:"source"`
	Epoch           int64  `json:"epoch"`
	OriginalDSNFile string `json:"original_dsn_file"`
	ReadDSNFile     string `json:"read_dsn_file"`
	ApproveDSNFile  string `json:"approve_dsn_file"`
	ApplyDSNFile    string `json:"apply_dsn_file"`
	Parallel        int    `json:"parallel"`
	TimeoutMS       int    `json:"timeout_ms"`
}

/** 默认关闭。只检验显式配置的四个现有身份，失败时释放已开的连接。 */
func OpenRestoredShortfallControl(path string) (*service.MetonRestoredShortfallControl, func(), error) {
	if path == "" {
		return nil, func() {}, nil
	}
	raw, err := readFile("", path, 65536)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg restoredShortfallConfiguration
	source, ok := service.MetonSource()
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || cfg.Environment != source.Environment ||
		cfg.Source != source.Source || cfg.Epoch != source.Epoch || cfg.Epoch <= 1 || cfg.Parallel < 1 || cfg.Parallel > 16 || cfg.TimeoutMS < 1 || cfg.TimeoutMS > 30000 {
		return nil, func() {}, service.ErrMetonClosed
	}
	var history *service.RestoredShortfallKeyHistory
	if cfg.Epoch > 1 || cfg.HistoryFile != "" || cfg.HistoryHash != "" {
		if cfg.HistoryFile == "" || len(cfg.HistoryHash) != 64 {
			return nil, func() {}, service.ErrMetonClosed
		}
		material, e := readFile(filepath.Dir(path), cfg.HistoryFile, 65536)
		digest := sha256.Sum256(material)
		history = &service.RestoredShortfallKeyHistory{}
		if e != nil || hex.EncodeToString(digest[:]) != cfg.HistoryHash || metonexecution.DecodeStrict(material, history) != nil {
			return nil, func() {}, service.ErrMetonClosed
		}
	}
	pools := make([]*sql.DB, 0, 4)
	var once sync.Once
	closePools := func() {
		once.Do(func() {
			for _, p := range pools {
				_ = p.Close()
			}
		})
	}
	for _, name := range []string{cfg.OriginalDSNFile, cfg.ReadDSNFile, cfg.ApproveDSNFile, cfg.ApplyDSNFile} {
		secret, e := readFile(filepath.Dir(path), name, 32768)
		if e != nil {
			closePools()
			return nil, func() {}, service.ErrMetonClosed
		}
		db, e := sql.Open("postgres", strings.TrimSpace(string(secret)))
		if e != nil {
			closePools()
			return nil, func() {}, service.ErrMetonClosed
		}
		db.SetMaxOpenConns(cfg.Parallel)
		db.SetMaxIdleConns(1)
		db.SetConnMaxLifetime(5 * time.Minute)
		pools = append(pools, db)
	}
	control, err := newRestoredShortfallControl(source, pools, cfg.Parallel, time.Duration(cfg.TimeoutMS)*time.Millisecond, history)
	if err != nil {
		closePools()
		return nil, func() {}, err
	}
	return control, closePools, nil
}
