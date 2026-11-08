//go:build meton_managed

// Package metonprovider 只读取原供应结果；身份归属与资金效果仍由来源账本裁定。
package metonprovider

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
)

var ErrUnavailable = errors.New("original provider result unavailable")
var responseID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,256}$`)
var digestValue = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Binding 保存最终出站认证摘要而非秘密。账户 ID 来自原生连接池，不接受用户指定。
type Binding struct {
	Version        int    `json:"version"`
	Account        int64  `json:"account"`
	CredentialHash string `json:"credential_hash"`
	QueryKind      string `json:"query_kind"`
}

func (b Binding) Valid() bool {
	return b.Version == 1 && b.Account > 0 && digestValue.MatchString(b.CredentialHash) &&
		(b.QueryKind == "unavailable" || b.QueryKind == "responses_default")
}

/** Capture 观察原生转换后的正文与认证，不增加 store、不保留正文或头值。 */
func Capture(account int64, headers http.Header, protocol string, body []byte) (Binding, error) {
	_, fingerprint, err := authentication(headers)
	if err != nil || account < 1 {
		return Binding{}, ErrUnavailable
	}
	var input map[string]json.RawMessage
	if metonexecution.DecodeStrict(body, &input) != nil {
		return Binding{}, ErrUnavailable
	}
	b := Binding{Version: 1, Account: account, CredentialHash: fingerprint, QueryKind: "unavailable"}
	_, explicit := input["store"]
	// 默认保存只允许尝试查询，并不保证远端仍有结果；显式关闭保存的请求永不借查询重发。
	if protocol == "responses" && !explicit && !hasHeader(headers, "Cookie") && !hasHeader(headers, "Chatgpt-Account-Id") {
		b.QueryKind = "responses_default"
	}
	return b, nil
}

func hasHeader(h http.Header, name string) bool {
	for key := range h {
		if strings.EqualFold(key, name) {
			return true
		}
	}
	return false
}

/** authentication 固定原认证与组织／项目；重复头和大小写别名不能产生歧义。 */
func authentication(h http.Header) (http.Header, string, error) {
	names := []string{"Authorization", "OpenAI-Organization", "OpenAI-Project"}
	values := make([]string, len(names))
	result := http.Header{}
	for i, name := range names {
		count := 0
		for key, items := range h {
			if !strings.EqualFold(key, name) {
				continue
			}
			count++
			if count > 1 || len(items) != 1 || items[0] == "" || strings.TrimSpace(items[0]) != items[0] || len(items[0]) > 16391 {
				return nil, "", ErrUnavailable
			}
			for _, c := range items[0] {
				if c < 32 || c > 126 {
					return nil, "", ErrUnavailable
				}
			}
			values[i] = items[0]
			result.Set(name, items[0])
		}
	}
	if !strings.HasPrefix(values[0], "Bearer ") || len(values[0]) == 7 || strings.ContainsAny(values[0][7:], " \t") {
		return nil, "", ErrUnavailable
	}
	encoded, _ := json.Marshal(values)
	sum := sha256.Sum256(encoded)
	return result, hex.EncodeToString(sum[:]), nil
}

/** originalAuthentication 只恢复原摘要证明存在的头；当前配置新增组织／项目不扩大原查询范围。 */
func originalAuthentication(h http.Header, expected string) (http.Header, error) {
	canonical, _, e := authentication(h)
	if e != nil {
		return nil, ErrUnavailable
	}
	for mask := 0; mask < 4; mask++ {
		candidate := canonical.Clone()
		if mask&1 != 0 {
			candidate.Del("OpenAI-Organization")
		}
		if mask&2 != 0 {
			candidate.Del("OpenAI-Project")
		}
		selected, hash, e := authentication(candidate)
		if e == nil && hash == expected {
			return selected, nil
		}
	}
	return nil, ErrUnavailable
}

// Credentials 只能从原供应账户取当前材料；摘要不符时不能偷偷借用轮换后的凭据。
type Credentials func(context.Context, int64) (http.Header, error)

// Reader 使用固定部署目标和独立只读 HTTP；不与原模型 POST 的发送权混用。
type Reader struct {
	client  *http.Client
	targets map[string]string
	slots   chan struct{}
	timeout time.Duration
}

/** NewReader 拒绝隐藏重试 Transport、关闭证书校验及模糊目标；并发无空闲时直接待核对。 */
func NewReader(client *http.Client, targets []string, parallel int, timeout time.Duration) (*Reader, error) {
	if client == nil || len(targets) == 0 || len(targets) > 128 || parallel < 1 || parallel > 16 || timeout <= 0 || timeout > 30*time.Second {
		return nil, ErrUnavailable
	}
	transport, ok := client.Transport.(*http.Transport)
	if !ok || transport == nil || transport.TLSClientConfig != nil && transport.TLSClientConfig.InsecureSkipVerify {
		return nil, ErrUnavailable
	}
	r := &Reader{targets: map[string]string{}, slots: make(chan struct{}, parallel), timeout: timeout}
	for _, target := range targets {
		u, e := url.Parse(target)
		if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.RawPath != "" ||
			!strings.HasSuffix(u.Path, "/responses") || u.String() != target || strings.Contains(u.Path, "//") {
			return nil, ErrUnavailable
		}
		sum := sha256.Sum256([]byte(target))
		hash := hex.EncodeToString(sum[:])
		if _, exists := r.targets[hash]; exists {
			return nil, ErrUnavailable
		}
		r.targets[hash] = target
	}
	t := transport.Clone()
	t.DisableCompression = true
	r.client = &http.Client{Transport: t, Timeout: timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return r, nil
}

/** Close 只释放本读取器的闲置连接，不关闭注入的原生连接池。 */
func (r *Reader) Close() {
	if r != nil {
		r.client.CloseIdleConnections()
	}
}

/** Read 只能 GET 原响应。完整终局仍须登记来源凭证，本返回值没有资金或人员授权。 */
func (r *Reader) Read(ctx context.Context, b Binding, spec metonexecution.Record, id string, credentials Credentials, current func(context.Context) error) (metonresult.Snapshot, error) {
	invalid := func() (metonresult.Snapshot, error) { return metonresult.Snapshot{}, ErrUnavailable }
	if r == nil || ctx == nil || ctx.Err() != nil || !b.Valid() || b.QueryKind != "responses_default" || spec.Version != 1 || spec.WireProtocol != "responses" ||
		spec.WireModel == "" || !responseID.MatchString(id) || credentials == nil || current == nil {
		return invalid()
	}
	target, allowed := r.targets[spec.TargetHash]
	if !allowed {
		return invalid()
	}
	select {
	case r.slots <- struct{}{}:
		defer func() { <-r.slots }()
	default:
		return invalid()
	}
	ctx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()
	if current(ctx) != nil {
		return invalid()
	}
	h, err := credentials(ctx, b.Account)
	if err != nil {
		return invalid()
	}
	headers, err := originalAuthentication(h, b.CredentialHash)
	if err != nil || hasHeader(h, "Cookie") || hasHeader(h, "Chatgpt-Account-Id") || current(ctx) != nil {
		return invalid()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target+"/"+id, nil)
	if err != nil {
		return invalid()
	}
	request.Header = headers
	request.Header.Set("Accept", "application/json")
	response, err := r.client.Do(request)
	if response != nil && response.Body != nil {
		defer response.Body.Close()
	}
	if err != nil || response == nil || response.Body == nil || response.StatusCode != http.StatusOK || response.ContentLength > metonresult.MaxMetadataBytes ||
		response.Header.Get("Content-Encoding") != "" && response.Header.Get("Content-Encoding") != "identity" {
		return invalid()
	}
	media, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		return invalid()
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, metonresult.MaxMetadataBytes+1))
	if err != nil || len(raw) == 0 || len(raw) > metonresult.MaxMetadataBytes || ctx.Err() != nil {
		return invalid()
	}
	var result metonresult.Snapshot
	observed, err := metonresult.New(io.NopCloser(bytes.NewReader(raw)), spec.WireProtocol, spec.WireModel, "application/json", 200, func(s metonresult.Snapshot) { result = s })
	if err != nil {
		return invalid()
	}
	_, err = io.Copy(io.Discard, observed)
	_ = observed.Close()
	if err != nil || !result.Valid() || !result.FeeReady || result.Execution == "unknown" || result.ReadEnd != "eof" || result.ResponseID != id || current(ctx) != nil || ctx.Err() != nil {
		return invalid()
	}
	return result, nil
}
