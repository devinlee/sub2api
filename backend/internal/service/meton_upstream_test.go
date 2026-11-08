//go:build meton_managed && dispatch_integration && unit

package service

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
	"github.com/Wei-Shaw/sub2api/internal/pkg/tlsfingerprint"
	"github.com/gin-gonic/gin"
)

type metonNativeTestUpstream struct{ transport *http.Transport }

func (u *metonNativeTestUpstream) Do(r *http.Request, _ string, _ int64, _ int) (*http.Response, error) {
	client, err := metontransport.Client(&http.Client{Transport: u.transport}, r)
	if err != nil {
		return nil, err
	}
	return client.Do(r)
}
func (u *metonNativeTestUpstream) DoWithTLS(r *http.Request, p string, a int64, c int, _ *tlsfingerprint.Profile) (*http.Response, error) {
	return u.Do(r, p, a, c)
}

/** 复用真实 Responses→Chat 转换与 Chat 原生转发；原生服务再次调用及换账户都只有一笔实际网络。 */
func TestMetonNativeGatewayDispatch(t *testing.T) {
	gin.SetMode(gin.TestMode)
	signer := dispatchtest.New(t)
	for _, protocol := range []string{"responses", "chat_completions"} {
		for _, mode := range []string{"success", "server-error"} {
			t.Run(protocol+"/"+mode, func(t *testing.T) {
				body := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic","stream":false}`)
				path := "/v1/responses"
				if protocol == "chat_completions" {
					body = []byte(`{"model":"meton-s2-text-fixture","messages":[{"role":"user","content":"synthetic"}],"stream":false}`)
					path = "/v1/chat/completions"
				}
				key := []byte("synthetic-key")
				proof := dispatchtest.Context(body, key)
				proof.Protocol = protocol
				v := signer.Verify(t, proof, body, key)
				var calls, claims atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls.Add(1)
					_, _ = io.Copy(io.Discard, r.Body)
					_ = r.Body.Close()
					if r.URL.Path != "/v1/chat/completions" {
						t.Error("native conversion route differs", r.URL.Path)
					}
					w.Header().Set("Content-Type", "application/json")
					if mode == "server-error" {
						w.WriteHeader(503)
						_, _ = w.Write([]byte(`{"error":{"message":"synthetic unavailable"}}`))
						return
					}
					_, _ = w.Write([]byte(`{"id":"synthetic-response","object":"chat.completion","model":"meton-s2-text-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"synthetic"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`))
				}))
				defer server.Close()
				ctx, err := metontransport.Bind(t.Context(), v, func(context.Context) (bool, error) { claims.Add(1); return true, nil })
				if err != nil {
					t.Fatal(err)
				}
				transport := http.DefaultTransport.(*http.Transport).Clone()
				defer transport.CloseIdleConnections()
				svc := &OpenAIGatewayService{cfg: rawChatCompletionsTestConfig(), httpUpstream: &metonNativeTestUpstream{transport}}
				for i := 0; i < 3; i++ {
					account := forceChatResponsesFallbackAccount()
					account.ID = int64(i + 1)
					account.Credentials["base_url"] = server.URL
					c, _ := gin.CreateTestContext(httptest.NewRecorder())
					c.Request = httptest.NewRequest("POST", path, strings.NewReader(string(body))).WithContext(ctx)
					var result *OpenAIForwardResult
					if protocol == "responses" {
						result, err = svc.Forward(ctx, c, account, body)
					} else {
						result, err = svc.ForwardAsChatCompletions(ctx, c, account, body, "", "")
					}
					if i == 0 && mode == "success" && (err != nil || result == nil) {
						t.Fatal("initial native request failed", err)
					}
					if i > 0 && err == nil {
						t.Error("retry succeeded")
					}
					var failover *UpstreamFailoverError
					if errors.As(err, &failover) {
						t.Error("original request error grants account failover")
					}
				}
				if calls.Load() != 1 || claims.Load() != 1 {
					t.Fatalf("calls=%d claims=%d", calls.Load(), claims.Load())
				}
			})
		}
	}
}

/** 缺受理、独立插件与非 OpenAI 路由在实际出站前拒绝，不把插件不可用当作隐式直连许可。 */
func TestMetonNativeGatewayBoundaries(t *testing.T) {
	signer := dispatchtest.New(t)
	body, key := []byte(`{"input":"synthetic"}`), []byte("synthetic-key")
	v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
	var claims atomic.Int32
	ctx, err := metontransport.Bind(t.Context(), v, func(context.Context) (bool, error) { claims.Add(1); return true, nil })
	if err != nil {
		t.Fatal(err)
	}
	plugins := &PluginManager{}
	plugins.route.Store(&pluginRoute{pluginID: 1, rolloutPercent: 100, unavailable: "synthetic"})
	for _, a := range []*Account{nil, {ID: 1, Platform: PlatformGrok, Type: AccountTypeOAuth}, {ID: 2, Platform: PlatformOpenAI, Type: AccountTypeOAuth}} {
		if !errors.Is(metonModelForwardAllowed(ctx, a, plugins), ErrMetonClosed) {
			t.Fatal("unsupported path allowed")
		}
	}
	account := rawChatCompletionsTestAccount()
	if !errors.Is(metonModelForwardAllowed(t.Context(), account, nil), ErrMetonClosed) {
		t.Fatal("missing binding allowed")
	}
	if err = metonModelForwardAllowed(ctx, account, plugins); err != nil {
		t.Fatal("unrelated plugin blocks API-key account", err)
	}
	if err = metonModelForwardAllowed(ctx, &Account{ID: 2, Platform: PlatformOpenAI, Type: AccountTypeOAuth}, nil); err != nil {
		t.Fatal("native OAuth HTTP unavailable", err)
	}
	if claims.Load() != 0 {
		t.Fatal("preflight consumed send")
	}
	// 模拟旧转发脱离取消；资格错误不生成账户失败事件，也不交回可自动重试的错误。
	original, cancel := context.WithCancel(t.Context())
	detached, err := metontransport.Bind(original, v, func(context.Context) (bool, error) { return true, nil })
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	detached = context.WithoutCancel(detached)
	svc := &OpenAIGatewayService{}
	result := svc.handleOpenAIUpstreamTransportError(detached, nil, account, metontransport.ErrUnavailable, false)
	var failover *UpstreamFailoverError
	if !errors.Is(result, ErrMetonClosed) || errors.As(result, &failover) {
		t.Fatal("cancelled request entered account failure path")
	}
}
