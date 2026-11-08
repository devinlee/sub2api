//go:build meton_managed && dispatch_integration

package repository

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
	"github.com/Wei-Shaw/sub2api/internal/pkg/tlsfingerprint"
)

/** 使用真实原生连接池、HTTP 代理与账户编号切换，按上游实际收到的请求计数。 */
func TestMetonNativeTransport(t *testing.T) {
	signer := dispatchtest.New(t)
	body, key := []byte(`{"input":"synthetic"}`), []byte("synthetic-key")
	for _, mode := range []string{"success", "server-error", "redirect", "connection-lost", "unknown-claim", "proxy"} {
		t.Run(mode, func(t *testing.T) {
			var calls, claims, redirects atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/redirected" {
					redirects.Add(1)
					w.WriteHeader(200)
					return
				}
				calls.Add(1)
				_, _ = io.Copy(io.Discard, r.Body)
				_ = r.Body.Close()
				if r.Header.Get("Meton-Model-Context") != "" || r.Header.Get("Idempotency-Key") != "" {
					t.Error("private header forwarded")
				}
				switch mode {
				case "redirect":
					w.Header().Set("Location", "/redirected")
					w.WriteHeader(307)
				case "server-error":
					w.WriteHeader(500)
				case "connection-lost":
					conn, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					_ = conn.Close()
				default:
					_, _ = w.Write([]byte("synthetic"))
				}
			}))
			defer server.Close()
			v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
			ctx, err := metontransport.Bind(t.Context(), v, func(context.Context) (bool, error) { claims.Add(1); return mode != "unknown-claim", nil })
			if err != nil {
				t.Fatal(err)
			}
			upstream := NewHTTPUpstream(nil).(*httpUpstreamService)
			defer func() {
				for _, entry := range upstream.clients {
					entry.client.CloseIdleConnections()
				}
			}()
			for i := 0; i < 4; i++ {
				url, proxy := server.URL+"/v1/responses", ""
				if mode == "proxy" {
					url = "http://synthetic.invalid/v1/responses"
					proxy = server.URL
				}
				r, _ := http.NewRequestWithContext(context.WithoutCancel(ctx), "POST", url, strings.NewReader(string(body)))
				r.Header.Set("Meton-Model-Context", "must-not-forward")
				r.Header.Set("Idempotency-Key", "retry-trigger")
				var response *http.Response
				if i%2 == 0 {
					response, err = upstream.Do(r, proxy, int64(i+1), 1)
				} else {
					response, err = upstream.DoWithTLS(r, proxy, int64(i+1), 1, &tlsfingerprint.Profile{Name: "plain-http-keeps-proxy"})
				}
				if response != nil {
					_, _ = io.Copy(io.Discard, response.Body)
					_ = response.Body.Close()
				}
				if i > 0 && err == nil {
					t.Error("account retry reached upstream")
				}
			}
			want := int32(1)
			if mode == "unknown-claim" {
				want = 0
			}
			if calls.Load() != want || claims.Load() != 1 || redirects.Load() != 0 {
				t.Fatalf("calls=%d claims=%d redirects=%d", calls.Load(), claims.Load(), redirects.Load())
			}
			for _, entry := range upstream.clients {
				if atomic.LoadInt64(&entry.inFlight) != 0 {
					t.Error("connection pool slot leaked")
				}
			}
		})
	}
}

/** 丢失内部上下文时拒绝；客户端伪造证明头或复用池不能直接取得供应网络权限。 */
func TestMetonNativeTransportMissingBinding(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls.Add(1) }))
	defer server.Close()
	r, _ := http.NewRequest("POST", server.URL, strings.NewReader("synthetic"))
	r.Header.Set("Meton-Service-Proof", "forged")
	upstream := NewHTTPUpstream(nil).(*httpUpstreamService)
	defer func() {
		for _, entry := range upstream.clients {
			entry.client.CloseIdleConnections()
		}
	}()
	response, err := upstream.Do(r, "", 1, 1)
	if err == nil || response != nil || calls.Load() != 0 {
		t.Fatal("unbound request reached native network")
	}
	for _, entry := range upstream.clients {
		if atomic.LoadInt64(&entry.inFlight) != 0 {
			t.Error("rejection leaked pool slot")
		}
	}
}
