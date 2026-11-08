//go:build meton_managed

package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type sourceObservationConfig struct {
	FormatVersion int    `json:"format_version"`
	Environment   string `json:"environment"`
	Source        string `json:"source"`
	Epoch         int64  `json:"epoch"`
	Replica       string `json:"replica"`
	IntervalMS    int    `json:"interval_ms"`
}

/** sourceObservationFile 有界读取普通部署文件；不包含秘密，错误也不输出配置路径或文件内容。 */
func sourceObservationFile(path string) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, metonobserve.ErrConfiguration
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() < 1 || info.Size() > 4096 {
		return nil, metonobserve.ErrConfiguration
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, metonobserve.ErrConfiguration
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, 4097))
	if err != nil || len(raw) == 0 || len(raw) > 4096 {
		return nil, metonobserve.ErrConfiguration
	}
	return raw, nil
}

/** openMetonSourceObservation 默认不装配；只按完整配置输出进程计数，不新增管理 HTTP 或资金权限。 */
func openMetonSourceObservation() (func(), error) {
	path := os.Getenv("METON_MANAGED_OBSERVATION_CONFIG")
	if path == "" {
		return func() {}, nil
	}
	raw, err := sourceObservationFile(path)
	var config sourceObservationConfig
	source, ok := service.MetonSource()
	if err != nil || !ok || os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || metonexecution.DecodeStrict(raw, &config) != nil ||
		config.FormatVersion != 1 || config.Environment != source.Environment || config.Source != source.Source || config.Epoch != source.Epoch ||
		config.IntervalMS < 1000 || config.IntervalMS > 60000 {
		return func() {}, metonobserve.ErrConfiguration
	}
	collector, err := metonobserve.Install(metonobserve.Scope{Environment: config.Environment, Source: config.Source, Epoch: config.Epoch}, config.Replica)
	if err != nil {
		return func() {}, err
	}
	current := func() bool {
		live, ok := service.MetonSource()
		if !ok || live != source || os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || os.Getenv("METON_MANAGED_OBSERVATION_CONFIG") != path {
			return false
		}
		data, err := sourceObservationFile(path)
		return err == nil && bytes.Equal(data, raw)
	}
	ctx, cancel := context.WithCancel(context.Background())
	close := sync.OnceFunc(func() { cancel(); collector.Close() })
	go func() {
		defer close()
		ticker := time.NewTicker(time.Duration(config.IntervalMS) * time.Millisecond)
		defer ticker.Stop()
		for {
			if ctx.Err() != nil {
				return
			}
			if !current() {
				slog.Warn("meton_source_observation_retired", "reason", "configuration_changed")
				return
			}
			snapshot, available := collector.Snapshot()
			if !available || !current() || ctx.Err() != nil {
				return
			}
			encoded, _ := json.Marshal(snapshot)
			// 日志在单个后台内输出；请求线程只累加固定数组，不因拒绝洪峰增加日志任务。
			slog.Info("meton_source_rejections", "snapshot", string(encoded))
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	return close, nil
}
