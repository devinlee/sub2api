//go:build meton_managed

package metonentry

import (
	"database/sql"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type shortfallConfiguration struct {
	FormatVersion   int    `json:"format_version"`
	Environment     string `json:"environment"`
	Source          string `json:"source"`
	Epoch           int64  `json:"epoch"`
	OriginalDSNFile string `json:"original_dsn_file"`
	ReadDSNFile     string `json:"read_dsn_file"`
	ApplyDSNFile    string `json:"apply_dsn_file"`
	Parallel        int    `json:"parallel"`
	TimeoutMS       int    `json:"timeout_ms"`
}

/** 配置缺省关闭；显式开启只验证已有权限，不建库、迁移、补秘密或放开原服务。 */
func OpenShortfallControl(path string) (*service.MetonShortfallControl, func(), error) {
	if path == "" {
		return nil, func() {}, nil
	}
	raw, err := readFile("", path, 65536)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg shortfallConfiguration
	source, ok := service.MetonSource()
	id, enabled := source.ShortfallControlID("apply")
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || !enabled ||
		cfg.Environment != source.Environment || cfg.Source != source.Source || cfg.Epoch != source.Epoch ||
		cfg.Parallel < 1 || cfg.Parallel > 16 || cfg.TimeoutMS < 1 || cfg.TimeoutMS > 30000 {
		return nil, func() {}, service.ErrMetonClosed
	}
	base := filepath.Dir(path)
	pools := []*sql.DB{}
	var once sync.Once
	close := func() {
		once.Do(func() {
			for _, p := range pools {
				_ = p.Close()
			}
		})
	}
	success := false
	defer func() {
		if !success {
			close()
		}
	}()
	for _, name := range []string{cfg.OriginalDSNFile, cfg.ReadDSNFile, cfg.ApplyDSNFile} {
		secret, err := readFile(base, name, 32768)
		if err != nil {
			return nil, func() {}, err
		}
		pool, err := sql.Open("postgres", strings.TrimSpace(string(secret)))
		if err != nil {
			return nil, func() {}, service.ErrMetonClosed
		}
		pools = append(pools, pool)
		pool.SetMaxOpenConns(cfg.Parallel)
		pool.SetMaxIdleConns(1)
		pool.SetConnMaxLifetime(5 * time.Minute)
	}
	result, err := NewShortfallControl(pools[0], pools[1], pools[2], cfg.Parallel, time.Duration(cfg.TimeoutMS)*time.Millisecond)
	if err != nil {
		return nil, func() {}, err
	}
	now, ok := service.MetonSource()
	current, enabled := source.ShortfallControlID("apply")
	if !ok || now != source || !enabled || current != id {
		return nil, func() {}, service.ErrMetonClosed
	}
	success = true
	return result, close, nil
}
