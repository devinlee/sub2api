//go:build unit && meton_managed

package metonprovider

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const finalResponse = `{"id":"resp_original","object":"response","model":"text-fixture","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"private response"}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2,"input_tokens_details":{"cached_tokens":0}}}`

func headers() http.Header {
	return http.Header{"Authorization": []string{"Bearer synthetic-only"}, "Openai-Organization": []string{"original-org"}, "Openai-Project": []string{"original-project"}}
}
func binding(t *testing.T) Binding {
	t.Helper()
	b, e := Capture(23, headers(), "responses", []byte(`{"model":"text-fixture","input":"private prompt"}`))
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func trusted(s *httptest.Server) *http.Client {
	c := s.Client()
	tr := c.Transport.(*http.Transport).Clone()
	tr.TLSClientConfig = tr.TLSClientConfig.Clone()
	roots := x509.NewCertPool()
	roots.AddCert(s.Certificate())
	tr.TLSClientConfig.RootCAs = roots
	tr.TLSClientConfig.InsecureSkipVerify = false
	return &http.Client{Transport: tr}
}
func setupReader(t *testing.T, handler http.HandlerFunc, parallel int, timeout time.Duration) (*Reader, metonexecution.Record) {
	t.Helper()
	s := httptest.NewTLSServer(handler)
	t.Cleanup(s.Close)
	target := s.URL + "/v1/responses"
	r, e := NewReader(trusted(s), []string{target}, parallel, timeout)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(r.Close)
	sum := sha256.Sum256([]byte(target))
	return r, metonexecution.Record{Version: 1, WireProtocol: "responses", WireModel: "text-fixture", TargetHash: hex.EncodeToString(sum[:])}
}
func credentials(_ context.Context, id int64) (http.Header, error) {
	if id != 23 {
		return nil, errors.New("wrong original account")
	}
	h := headers()
	h.Set("X-Client-Secret", "not-forwarded")
	return h, nil
}
func current(context.Context) error { return nil }

/** 新增配置头只能按原摘要恢复，不能借此换到另一组织或项目；旧错误凭据仍拒绝。 */
func TestOriginalProviderAuthenticationDelta(t *testing.T) {
	var calls atomic.Int32
	r, spec := setupReader(t, func(w http.ResponseWriter, q *http.Request) {
		calls.Add(1)
		if q.Header.Get("OpenAI-Organization") != "" || q.Header.Get("OpenAI-Project") != "" {
			t.Error("后来配置扩大原认证范围")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(finalResponse))
	}, 1, time.Second)
	old := headers()
	old.Del("OpenAI-Organization")
	old.Del("OpenAI-Project")
	b, e := Capture(23, old, "responses", []byte(`{}`))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = r.Read(t.Context(), b, spec, "resp_original", credentials, current); e != nil || calls.Load() != 1 {
		t.Fatal("不能恢复原来省略的头", e)
	}
	for _, name := range []string{"Authorization", "OpenAI-Organization", "OpenAI-Project"} {
		exact := binding(t)
		get := func(context.Context, int64) (http.Header, error) {
			h := headers()
			if name == "Authorization" {
				h.Set(name, "Bearer changed")
			} else {
				h.Set(name, "changed")
			}
			return h, nil
		}
		if _, e = r.Read(t.Context(), exact, spec, "resp_original", get, current); e == nil || calls.Load() != 1 {
			t.Fatal("原认证范围变化仍发送", name)
		}
	}
	// 实际超时必须收敛为待核对，没有后台补发；不沿测试钩子制造完成。
	timeoutReader, timeoutSpec := setupReader(t, func(w http.ResponseWriter, q *http.Request) { <-q.Context().Done() }, 1, 30*time.Millisecond)
	if _, e = timeoutReader.Read(t.Context(), binding(t), timeoutSpec, "resp_original", credentials, current); e == nil {
		t.Fatal("超时被当成完成")
	}
}

func TestOriginalProviderCapture(t *testing.T) {
	b := binding(t)
	raw, _ := json.Marshal(b)
	if !b.Valid() || b.QueryKind != "responses_default" || strings.Contains(string(raw), "synthetic-only") || strings.Contains(string(raw), "private") {
		t.Fatal("供应绑定泄露秘密或改变原查询范围")
	}
	for _, item := range []struct {
		name, protocol, body string
		mutate               func(http.Header)
	}{
		{"store_disabled", "responses", `{"store":false}`, nil}, {"chat_not_retrievable", "chat_completions", `{}`, nil},
		{"oauth_account", "responses", `{}`, func(h http.Header) { h.Set("Chatgpt-Account-Id", "owner") }},
		{"cookie", "responses", `{}`, func(h http.Header) { h.Set("Cookie", "original=x") }},
	} {
		t.Run(item.name, func(t *testing.T) {
			h := headers()
			if item.mutate != nil {
				item.mutate(h)
			}
			got, e := Capture(23, h, item.protocol, []byte(item.body))
			if e != nil || got.QueryKind != "unavailable" {
				t.Fatal("不可检索路线被放行", e)
			}
		})
	}
	for _, name := range []string{"account", "alias", "duplicate", "empty", "malformed_body"} {
		t.Run(name, func(t *testing.T) {
			h := headers()
			id := int64(23)
			body := []byte(`{}`)
			switch name {
			case "account":
				id = 0
			case "alias":
				h["authorization"] = []string{"Bearer other"}
			case "duplicate":
				h.Add("Authorization", "Bearer other")
			case "empty":
				h.Set("Authorization", "Bearer ")
			case "malformed_body":
				body = []byte(`{"store":false,"store":false}`)
			}
			if _, e := Capture(id, h, "responses", body); e == nil {
				t.Fatal("歧义供应绑定通过")
			}
		})
	}
}

func TestOriginalProviderHTTPSResult(t *testing.T) {
	for _, mode := range []string{"complete", "wrong_response", "wrong_model", "pending", "usage_missing", "status", "redirect", "oversized", "truncated", "sse", "encoding", "guard_after"} {
		t.Run(mode, func(t *testing.T) {
			var calls atomic.Int32
			var crossed atomic.Bool
			r, spec := setupReader(t, func(w http.ResponseWriter, q *http.Request) {
				calls.Add(1)
				if q.Method != "GET" || q.URL.Path != "/v1/responses/resp_original" || q.URL.RawQuery != "" || q.ContentLength != 0 ||
					q.Header.Get("Authorization") != "Bearer synthetic-only" || q.Header.Get("OpenAI-Organization") != "original-org" || q.Header.Get("X-Client-Secret") != "" {
					t.Error("查询改变原路线或泄露额外头")
				}
				w.Header().Set("Content-Type", "application/json")
				raw := finalResponse
				switch mode {
				case "wrong_response":
					raw = strings.ReplaceAll(raw, "resp_original", "resp_foreign")
				case "wrong_model":
					raw = strings.ReplaceAll(raw, "text-fixture", "other-model")
				case "pending":
					raw = strings.ReplaceAll(raw, "completed", "in_progress")
				case "usage_missing":
					raw = strings.ReplaceAll(raw, `"cached_tokens":0`, `"other":0`)
				case "status":
					w.WriteHeader(404)
				case "redirect":
					w.Header().Set("Location", "/v1/responses/resp_other")
					w.WriteHeader(307)
				case "oversized":
					raw = strings.Repeat(" ", 1024*1024+1) + raw
				case "truncated":
					w.Header().Set("Content-Length", "999999")
				case "sse":
					w.Header().Set("Content-Type", "text/event-stream")
				case "encoding":
					w.Header().Set("Content-Encoding", "gzip")
				case "guard_after":
					crossed.Store(true)
				}
				_, _ = w.Write([]byte(raw))
			}, 1, time.Second)
			guard := func(context.Context) error {
				if crossed.Load() {
					return errors.New("source recovery started")
				}
				return nil
			}
			got, e := r.Read(t.Context(), binding(t), spec, "resp_original", credentials, guard)
			if mode == "complete" {
				if e != nil || !got.FeeReady || got.Usage.Input != 1 || got.Usage.Output != 1 {
					t.Fatal("原 GET 未取得明确终局", e)
				}
				raw, _ := json.Marshal(got)
				if strings.Contains(string(raw), "private response") || strings.Contains(string(raw), "synthetic-only") {
					t.Fatal("凭证泄露正文")
				}
			} else if e == nil {
				t.Fatal("异常查询被当作可结算终局", got)
			}
			if calls.Load() != 1 {
				t.Fatal("原查询发生跳转或重试", calls.Load())
			}
		})
	}
}

func TestOriginalProviderNoSendAndLimits(t *testing.T) {
	var calls atomic.Int32
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	r, spec := setupReader(t, func(w http.ResponseWriter, q *http.Request) {
		calls.Add(1)
		entered <- struct{}{}
		select {
		case <-release:
		case <-q.Context().Done():
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(finalResponse))
	}, 1, time.Second)
	for _, mode := range []string{"credential_changed", "account_changed", "target_changed", "store_false", "response_path", "guard", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			b := binding(t)
			s := spec
			id := "resp_original"
			get := Credentials(credentials)
			guard := current
			ctx := t.Context()
			switch mode {
			case "credential_changed":
				get = func(context.Context, int64) (http.Header, error) {
					h := headers()
					h.Set("Authorization", "Bearer rotated")
					return h, nil
				}
			case "account_changed":
				b.Account++
			case "target_changed":
				s.TargetHash = strings.Repeat("a", 64)
			case "store_false":
				b.QueryKind = "unavailable"
			case "response_path":
				id = "../foreign"
			case "guard":
				guard = func(context.Context) error { return errors.New("revoked") }
			case "cancelled":
				c, cancel := context.WithCancel(ctx)
				cancel()
				ctx = c
			}
			if _, e := r.Read(ctx, b, s, id, get, guard); e == nil || calls.Load() != 0 {
				t.Fatal("无权读取仍发送", e, calls.Load())
			}
		})
	}
	done := make(chan error, 1)
	go func() {
		_, e := r.Read(t.Context(), binding(t), spec, "resp_original", credentials, current)
		done <- e
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("未进入受限读取")
	}
	if _, e := r.Read(t.Context(), binding(t), spec, "resp_original", credentials, current); e == nil || calls.Load() != 1 {
		t.Fatal("并发预算被突破")
	}
	close(release)
	if e := <-done; e != nil {
		t.Fatal(e)
	}
	for _, target := range []string{"http://example.test/responses", "https://example.test/responses?x=1", "https://user@example.test/responses", "https://example.test/responses#x"} {
		if _, e := NewReader(&http.Client{Transport: http.DefaultTransport}, []string{target}, 1, time.Second); e == nil {
			t.Fatal("不安全目标通过")
		}
	}
}
