//go:build meton_managed

package metonentry

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type backupAuthorityMaterial struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type backupAuthorityConfiguration struct {
	FormatVersion      int                     `json:"format_version"`
	Environment        string                  `json:"environment"`
	Source             string                  `json:"source"`
	AuthorityReference string                  `json:"authority_reference"`
	Endpoint           string                  `json:"endpoint"`
	CA                 backupAuthorityMaterial `json:"ca"`
	Certificate        backupAuthorityMaterial `json:"certificate"`
	PrivateKey         backupAuthorityMaterial `json:"private_key"`
}

type backupAuthorityFile struct {
	path, hash string
	limit      int64
	identity   os.FileInfo
}

/** 比较打开的真实文件身份，拒绝在当前查询期间用另一文件换回相同路径。 */
func (f backupAuthorityFile) same(other backupAuthorityFile) bool {
	return os.SameFile(f.identity, other.identity)
}

/** 有界读取普通部署文件；摘要不包含路径，错误不携带秘密材料。 */
func readBackupAuthorityFile(path string, limit int64) (backupAuthorityFile, []byte, error) {
	empty := backupAuthorityFile{}
	if !filepath.IsAbs(path) {
		return empty, nil, service.ErrBackupRetirementUnavailable
	}
	initial, err := os.Lstat(path)
	if err != nil || !initial.Mode().IsRegular() || initial.Size() < 1 || initial.Size() > limit {
		return empty, nil, service.ErrBackupRetirementUnavailable
	}
	file, err := os.Open(path)
	if err != nil {
		return empty, nil, service.ErrBackupRetirementUnavailable
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(initial, opened) {
		return empty, nil, service.ErrBackupRetirementUnavailable
	}
	raw, err := io.ReadAll(io.LimitReader(file, limit+1))
	final, statErr := os.Lstat(path)
	if err != nil || statErr != nil || !final.Mode().IsRegular() || !os.SameFile(opened, final) || int64(len(raw)) != opened.Size() || len(raw) == 0 || int64(len(raw)) > limit {
		return empty, nil, service.ErrBackupRetirementUnavailable
	}
	hash := sha256.Sum256(raw)
	return backupAuthorityFile{path, hex.EncodeToString(hash[:]), limit, opened}, raw, nil
}

/** 仅显式装配当前权威连接；文件来自还原范围外的部署输入，不从原备份或 Settings 表取默认配置。 */
func OpenBackupRetentionAuthority(path, environment, source string) (service.BackupRetentionAuthority, func(), error) {
	noop := func() {}
	if path == "" {
		return nil, noop, nil
	}
	file, raw, err := readBackupAuthorityFile(path, 16384)
	var cfg backupAuthorityConfiguration
	if err != nil || metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 ||
		!backupAuthorityPart(environment, 120) || !backupAuthorityPart(source, 120) || cfg.Environment != environment || cfg.Source != source ||
		!backupAuthorityPart(cfg.AuthorityReference, 80) {
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	endpoint, err := url.Parse(cfg.Endpoint)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil || endpoint.Path != backupAuthorityPath ||
		endpoint.RawPath != "" || endpoint.RawQuery != "" || endpoint.ForceQuery || endpoint.Fragment != "" || endpoint.Opaque != "" {
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	a := &backupRetentionAuthority{configuration: cfg, files: []backupAuthorityFile{file}}
	materials := [][]byte{}
	for _, ref := range []backupAuthorityMaterial{cfg.CA, cfg.Certificate, cfg.PrivateKey} {
		name := ref.Path
		if !filepath.IsAbs(name) {
			name = filepath.Join(filepath.Dir(path), name)
		}
		current, content, err := readBackupAuthorityFile(name, 65536)
		if err != nil || !backupAuthorityHash(ref.SHA256) || current.hash != ref.SHA256 {
			return nil, noop, service.ErrBackupRetirementUnavailable
		}
		a.files = append(a.files, current)
		materials = append(materials, content)
	}
	roots := x509.NewCertPool()
	certificate, err := tls.X509KeyPair(materials[1], materials[2])
	if !roots.AppendCertsFromPEM(materials[0]) || err != nil || len(certificate.Certificate) == 0 {
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	leaf, err := x509.ParseCertificate(certificate.Certificate[0])
	now := time.Now()
	if err != nil || now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	a.transport = &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots, Certificates: []tls.Certificate{certificate}},
		TLSHandshakeTimeout: 3 * time.Second, ResponseHeaderTimeout: 8 * time.Second, MaxResponseHeaderBytes: 16384,
		DisableKeepAlives: true, DisableCompression: true, MaxConnsPerHost: 4}
	a.client = &http.Client{Transport: a.transport, Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	if !a.current() {
		a.close()
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	return a, a.close, nil
}
