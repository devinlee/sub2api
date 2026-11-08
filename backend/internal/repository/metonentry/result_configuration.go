//go:build meton_managed

package metonentry

import (
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type resultConfiguration struct {
	FormatVersion   int      `json:"format_version"`
	Environment     string   `json:"environment"`
	Source          string   `json:"source"`
	Epoch           int64    `json:"epoch"`
	OriginalDSNFile string   `json:"original_dsn_file"`
	ReadDSNFile     string   `json:"read_dsn_file"`
	ObserveDSNFile  string   `json:"observe_dsn_file"`
	ApplyDSNFile    string   `json:"apply_dsn_file"`
	Targets         []string `json:"targets"`
	Parallel        int      `json:"parallel"`
	TimeoutMS       int      `json:"timeout_ms"`
	CAFile          string   `json:"ca_file,omitempty"`
	ProxyFile       string   `json:"proxy_file,omitempty"`
}

/** OpenResultControl 只消费显式配置和已有权限；不建立账号、安装迁移或自动放开代理目标。 */
func OpenResultControl(path string, accounts ProviderAccountReader) (*service.MetonResultControl, func(), error) {
	if path == "" {
		return nil, func() {}, nil
	}
	raw, err := readFile("", path, 65536)
	if err != nil {
		return nil, func() {}, err
	}
	var cfg resultConfiguration
	source, ok := service.MetonSource()
	id, enabled := source.ResultControlID("apply")
	if metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 || !ok || !enabled || accounts == nil ||
		cfg.Environment != source.Environment || cfg.Source != source.Source || cfg.Epoch != source.Epoch || cfg.TimeoutMS < 1 || cfg.TimeoutMS > 30000 || cfg.Parallel < 1 || cfg.Parallel > 16 {
		return nil, func() {}, service.ErrMetonClosed
	}
	base := filepath.Dir(path)
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, MaxIdleConns: cfg.Parallel, MaxIdleConnsPerHost: cfg.Parallel, MaxConnsPerHost: cfg.Parallel, IdleConnTimeout: 30 * time.Second}
	if cfg.CAFile != "" {
		cert, err := readFile(base, cfg.CAFile, 65536)
		if err != nil {
			return nil, func() {}, err
		}
		roots, err := x509.SystemCertPool()
		if err != nil {
			return nil, func() {}, service.ErrMetonClosed
		}
		if !roots.AppendCertsFromPEM(cert) {
			return nil, func() {}, service.ErrMetonClosed
		}
		transport.TLSClientConfig.RootCAs = roots
	}
	if cfg.ProxyFile != "" {
		secret, err := readFile(base, cfg.ProxyFile, 8192)
		if err != nil {
			return nil, func() {}, err
		}
		proxy, err := url.Parse(strings.TrimSpace(string(secret)))
		if err != nil || (proxy.Scheme != "http" && proxy.Scheme != "https") || proxy.Hostname() == "" || proxy.Path != "" || proxy.RawQuery != "" || proxy.Fragment != "" || proxy.ForceQuery {
			return nil, func() {}, service.ErrMetonClosed
		}
		transport.Proxy = http.ProxyURL(proxy)
	}
	reader, err := metonprovider.NewReader(&http.Client{Transport: transport}, cfg.Targets, cfg.Parallel, time.Duration(cfg.TimeoutMS)*time.Millisecond)
	if err != nil {
		return nil, func() {}, err
	}
	pools := []*sql.DB{}
	close := func() {
		reader.Close()
		for _, pool := range pools {
			_ = pool.Close()
		}
	}
	success := false
	defer func() {
		if !success {
			close()
		}
	}()
	for _, name := range []string{cfg.OriginalDSNFile, cfg.ReadDSNFile, cfg.ObserveDSNFile, cfg.ApplyDSNFile} {
		secret, err := readFile(base, name, 32768)
		if err != nil {
			return nil, func() {}, err
		}
		pool, err := sql.Open("postgres", strings.TrimSpace(string(secret)))
		if err != nil {
			return nil, func() {}, service.ErrMetonClosed
		}
		pools = append(pools, pool)
		pool.SetMaxOpenConns(4)
		pool.SetMaxIdleConns(1)
		pool.SetConnMaxLifetime(5 * time.Minute)
	}
	result, err := NewResultControl(pools[0], pools[1], pools[2], pools[3], reader, ProviderCredentials(accounts))
	if err != nil {
		return nil, func() {}, err
	}
	now, ok := service.MetonSource()
	current, enabled := source.ResultControlID("apply")
	if !ok || now != source || !enabled || current != id {
		return nil, func() {}, service.ErrMetonClosed
	}
	success = true
	return result, close, nil
}
