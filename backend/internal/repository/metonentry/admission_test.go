//go:build meton_managed && dispatch_integration && unit

package metonentry_test

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	ent "github.com/Wei-Shaw/sub2api/ent"
	_ "github.com/Wei-Shaw/sub2api/ent/runtime"
	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/pkg/openai_compat"
	native "github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

type entryFixture struct {
	Context metondispatch.Context
	Key     metonledger.SessionKey
	Secret  string
	Group   int64
}

func connection(t *testing.T, role string) *sql.DB {
	t.Helper()
	db, e := sql.Open("postgres", "host=127.0.0.1 port=5432 dbname=s2_grants sslmode=disable user="+role)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}
func ledger(t *testing.T, db *sql.DB) *metonledger.TextLedger {
	t.Helper()
	l, e := metonledger.NewTextLedger(db)
	if e != nil {
		t.Fatal(e)
	}
	return l
}
func environment(t *testing.T) {
	t.Helper()
	for k, v := range map[string]string{"FUNDS_MODE": "s2-source-v1", "ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "ISSUE_KEY_ID": strings.Repeat("3", 24), "INSPECT_KEY_ID": strings.Repeat("4", 24)} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
}

/** 实际主库 Key 鉴权、Gin 入口、原生协议转换、来源 H 和原生连接池处于同一调用。 */
func TestModelExecutionAdmissionPostgres(t *testing.T) {
	environment(t)
	gin.SetMode(gin.TestMode)
	var fixtures []entryFixture
	raw, e := os.ReadFile(os.Getenv("METON_EXECUTION_FIXTURE"))
	if e != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 4 {
		t.Fatal("missing execution fixture")
	}
	authDB := connection(t, "s2_entry_auth")
	client := ent.NewClient(ent.Driver(entsql.OpenDB(dialect.Postgres, authDB)))
	keyRepo := native.NewAPIKeyRepository(client, authDB)
	groups := native.NewGroupRepository(client, authDB)
	keys := service.NewAPIKeyService(keyRepo, nil, nil, nil, nil, nil, nil)
	defer keys.StopAuthCacheInvalidationSubscriber()
	reserve, send := ledger(t, connection(t, "s2_execution_reserve")), ledger(t, connection(t, "s2_execution_send"))
	complete, inspect := ledger(t, connection(t, "s2_execution_complete")), ledger(t, connection(t, "s2_execution_result_read"))
	admin := connection(t, "postgres")
	signer := dispatchtest.New(t)
	// 各层先独立读回同一真实 Key；错误只报阶段，不输出密钥材料。
	projected, e := keyRepo.GetByKeyForAuth(t.Context(), fixtures[0].Secret)
	if e != nil || projected == nil {
		t.Fatal("native authentication projection", e)
	}
	source, valid := service.CurrentMetonKeySource()
	if !valid {
		t.Fatal("source configuration invalid")
	}
	admitted, e := keyRepo.(service.ManagedAdmissionReader).CurrentManagedKey(t.Context(), source, projected.ID, projected.UserID, fixtures[0].Key.Fingerprint)
	if e != nil || !admitted {
		t.Fatal("current source key not admitted", e)
	}
	if _, e = keys.GetByKey(t.Context(), fixtures[0].Secret); e != nil {
		t.Fatal("native managed key service", e)
	}
	if _, e = groups.GetByID(t.Context(), fixtures[0].Group); e != nil {
		t.Fatal("native group projection", e)
	}
	for i, route := range []struct{ original, wire string }{{"responses", "responses"}, {"responses", "chat_completions"}, {"chat_completions", "chat_completions"}, {"chat_completions", "responses"}} {
		t.Run(route.original+"-to-"+route.wire, func(t *testing.T) {
			f := fixtures[i]
			var calls atomic.Int32
			var sentDigest atomic.Value
			wirePath := "/v1/responses"
			if route.wire == "chat_completions" {
				wirePath = "/v1/chat/completions"
			}
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				sent, _ := io.ReadAll(r.Body)
				sentDigest.Store(dispatchtest.Hash(sent))
				if r.URL.Path != wirePath {
					t.Error("wrong native upstream route", r.URL.Path)
				}
				if r.Header.Get(metondispatch.ProofHeader) != "" || r.Header.Get(metondispatch.ContextHeader) != "" {
					t.Error("gateway proof leaked")
				}
				w.Header().Set("Content-Type", "application/json")
				if route.wire == "responses" {
					response := `{"id":"resp-synthetic","object":"response","status":"completed","model":"meton-s2-text-fixture","output":[{"type":"message","id":"msg-x","status":"completed","role":"assistant","content":[{"type":"output_text","text":"synthetic","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}`
					var request struct {
						Stream bool `json:"stream"`
					}
					if err := json.Unmarshal(sent, &request); err != nil {
						t.Error("invalid native upstream body", err)
					}
					// Chat 转 Responses 会主动请求 SSE；夹具按实际请求给终止事件，不能用 JSON 假冒流结束。
					if request.Stream {
						w.Header().Set("Content-Type", "text/event-stream")
						_, _ = io.WriteString(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":"+response+"}\n\n")
					} else {
						_, _ = io.WriteString(w, response)
					}
				} else {
					_, _ = io.WriteString(w, `{"id":"synthetic-response","object":"chat.completion","model":"meton-s2-text-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"synthetic"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
				}
			}))
			defer upstream.Close()
			profile, e := metonexecution.NewFixtureProfile(metonexecution.Spec{Version: "fixture-window-v1", Protocol: route.original, Model: "meton-s2-text-fixture", WireProtocol: route.wire, WireModel: "meton-s2-text-fixture", Target: upstream.URL + wirePath, MaxBodyBytes: 256 * 1024, InputWindow: 1024, OutputWindow: 128})
			if e != nil {
				t.Fatal(e)
			}
			entry, e := metonentry.New(signer.Verifier, keys, groups, reserve, send, complete, inspect, []metonentry.Route{{Group: f.Group, Profiles: []*metonexecution.Profile{profile}}})
			if e != nil {
				t.Fatal(e)
			}
			cfg := &config.Config{Security: config.SecurityConfig{URLAllowlist: config.URLAllowlistConfig{AllowInsecureHTTP: true}}}
			pool := native.NewHTTPUpstream(cfg)
			svc := service.NewOpenAIGatewayService(nil, nil, nil, nil, nil, nil, nil, cfg, nil, nil, nil, nil, nil, pool, nil, nil, nil, nil, nil, nil, nil, nil)
			defer svc.CloseOpenAIWSPool()
			body := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic","stream":false}`)
			path := "/v1/responses"
			if route.original == "chat_completions" {
				body = []byte(`{"model":"meton-s2-text-fixture","messages":[{"role":"user","content":"synthetic"}],"stream":false}`)
				path = "/v1/chat/completions"
			}
			c := f.Context
			c.Protocol = route.original
			c.InputDigest = dispatchtest.Hash(body)
			c.ValidUntilMS = time.Now().Add(25 * time.Second).UnixMilli()
			header, proof := signer.Encode(t, c, path, time.Now())
			router := gin.New()
			router.POST(path, middleware.MetonTextAuth(entry), func(g *gin.Context) {
				key, ok := middleware.GetAPIKeyFromContext(g)
				if !ok || key.ID != f.Key.ID || key.GroupID == nil || *key.GroupID != f.Group {
					t.Error("wrong native admission")
					g.Status(500)
					return
				}
				billing := &service.BillingCacheService{}
				if billing.CheckBillingEligibility(g.Request.Context(), key.User, key, key.Group, nil, service.PlatformOpenAI) != nil {
					t.Error("native preflight rejected authenticated text")
				}
				foreign := *key
				foreign.UserID++
				if service.MetonTextAdmitted(g.Request.Context(), &foreign) {
					t.Error("native subject changed after admission")
				}
				actual, _ := io.ReadAll(g.Request.Body)
				mode := openai_compat.ResponsesSupportModeForceResponses
				if route.wire == "chat_completions" {
					mode = openai_compat.ResponsesSupportModeForceChatCompletions
				}
				account := &service.Account{ID: 101, Platform: service.PlatformOpenAI, Type: service.AccountTypeAPIKey, Concurrency: 1, Credentials: map[string]any{"api_key": "synthetic-provider-key", "base_url": upstream.URL}, Extra: map[string]any{openai_compat.ExtraKeyResponsesMode: string(mode)}}
				var err error
				if route.original == "responses" {
					_, err = svc.Forward(g.Request.Context(), g, account, actual)
				} else {
					_, err = svc.ForwardAsChatCompletions(g.Request.Context(), g, account, actual, "", "")
				}
				if err != nil && !g.Writer.Written() {
					g.Status(502)
				}
			})
			source := httptest.NewServer(router)
			defer source.Close()
			invoke := func(body []byte, header, proof, secret string) int {
				request, _ := http.NewRequest("POST", source.URL+path, bytes.NewReader(body))
				request.Header.Set("Authorization", "Bearer "+secret)
				request.Header.Set("Content-Type", "application/json")
				request.Header.Set(metondispatch.ContextHeader, header)
				request.Header.Set(metondispatch.ProofHeader, proof)
				response, err := http.DefaultClient.Do(request)
				if err != nil {
					t.Error(err)
					return 0
				}
				_, _ = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
				return response.StatusCode
			}
			var good atomic.Int32
			var wait sync.WaitGroup
			for n := 0; n < 8; n++ {
				wait.Add(1)
				go func() {
					defer wait.Done()
					if invoke(body, header, proof, f.Secret) == 200 {
						good.Add(1)
					}
				}()
			}
			wait.Wait()
			if calls.Load() != 1 || good.Load() != 1 {
				t.Fatalf("network=%d successful=%d", calls.Load(), good.Load())
			}
			var held, digest string
			var count int
			err := admin.QueryRow(`SELECT count(*),max(x.spec->>'body_digest'),max(r.quote)::text FROM meton_ledger.text_executions x JOIN meton_ledger.text_requests r USING(request_id) WHERE r.operation_id=$1`, c.OperationID).Scan(&count, &digest, &held)
			if err != nil || count != 1 || held != "1152.00000000" || digest != sentDigest.Load() {
				t.Fatalf("execution receipt count=%d quote=%s digestMatches=%v err=%v", count, held, digest == sentDigest.Load(), err)
			}
			if route.original != route.wire && digest == c.InputDigest {
				t.Fatal("converted body was not independently frozen")
			}
			wrong := c
			wrong.Dispatch = uuid.NewString()
			wrongHeader, wrongProof := signer.Encode(t, wrong, path, time.Now())
			if invoke(body, wrongHeader, wrongProof, f.Secret) == 200 || invoke(append(bytes.Clone(body), ' '), header, proof, f.Secret) == 200 || invoke(body, header, proof, fixtures[(i+1)%4].Secret) == 200 || calls.Load() != 1 {
				t.Fatal("altered sender body or foreign key dispatched")
			}
			fresh, err := keys.GetByKey(t.Context(), f.Secret)
			if err != nil || fresh.GroupID != nil || fresh.Group != nil {
				t.Fatal("admission mutated persistent native key")
			}
			if _, err = admin.Exec("UPDATE api_keys SET status='disabled' WHERE id=$1", f.Key.ID); err != nil {
				t.Fatal(err)
			}
			if _, err = keys.GetByKey(t.Context(), f.Secret); err == nil {
				t.Fatal("revoked key retained cached admission")
			}
			if invoke(body, header, proof, f.Secret) != 403 || calls.Load() != 1 {
				t.Fatal("revoked key accepted")
			}
		})
	}
	// 配置装配只打开受限连接池。此 HTTPS 目标从不发请求，不能借测试 HTTP 规格进入生产装配。
	dir := t.TempDir()
	cert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: signer.Certificate.Raw})
	if os.WriteFile(filepath.Join(dir, "gateway.pem"), cert, 0600) != nil {
		t.Fatal("write test public certificate")
	}
	for _, role := range []string{"reserve", "send", "complete", "result_read"} {
		dsn := fmt.Sprintf("host=127.0.0.1 port=5432 dbname=s2_grants sslmode=disable user=s2_execution_%s", role)
		if os.WriteFile(filepath.Join(dir, role+".dsn"), []byte(dsn), 0600) != nil {
			t.Fatal("write test DSN")
		}
	}
	configBody := map[string]any{"format_version": 2, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1, "gateways": map[string]string{"gateway-s2": "gateway.pem"}, "reserve_dsn_file": "reserve.dsn", "send_dsn_file": "send.dsn", "complete_dsn_file": "complete.dsn", "inspect_dsn_file": "result_read.dsn", "routes": []any{map[string]any{"group": fixtures[0].Group, "profiles": []metonexecution.Spec{{Version: "fixture-window-v1", Protocol: "responses", Model: "meton-s2-text-fixture", WireProtocol: "responses", WireModel: "meton-s2-text-fixture", Target: "https://not-contacted.invalid/v1/responses", MaxBodyBytes: 256 * 1024, InputWindow: 1024, OutputWindow: 128}}}}}
	configPath := filepath.Join(dir, "source.json")
	write := func() {
		b, _ := json.Marshal(configBody)
		if os.WriteFile(configPath, b, 0600) != nil {
			t.Fatal("write configuration")
		}
	}
	write()
	configured, close, err := metonentry.Open(configPath, keys, groups)
	if err != nil || configured == nil {
		t.Fatal("valid deployment configuration rejected", err)
	}
	close()
	close()
	for _, field := range []string{"complete_dsn_file", "inspect_dsn_file"} {
		previous := configBody[field]
		delete(configBody, field)
		write()
		if _, close, err := metonentry.Open(configPath, keys, groups); err == nil {
			close()
			t.Fatal("missing completion identity admitted", field)
		}
		configBody[field] = "reserve.dsn"
		write()
		if _, close, err := metonentry.Open(configPath, keys, groups); err == nil {
			close()
			t.Fatal("completion identity reused send permission", field)
		}
		configBody[field] = previous
	}
	configBody["format_version"] = 1
	write()
	if _, close, err := metonentry.Open(configPath, keys, groups); err == nil {
		close()
		t.Fatal("old configuration admitted without terminal accounting")
	}
	configBody["format_version"] = 2
	configBody["send_dsn_file"] = "reserve.dsn"
	write()
	if _, close, err := metonentry.Open(configPath, keys, groups); err == nil {
		close()
		t.Fatal("same role admitted")
	}
	configBody["send_dsn_file"] = "send.dsn"
	configBody["epoch"] = 2
	write()
	if _, close, err := metonentry.Open(configPath, keys, groups); err == nil {
		close()
		t.Fatal("foreign epoch admitted")
	}
	if _, err = admin.Exec("GRANT UPDATE(balance) ON public.users TO s2_execution_reserve"); err != nil {
		t.Fatal(err)
	}
	configBody["epoch"] = 1
	write()
	if _, close, err := metonentry.Open(configPath, keys, groups); err == nil {
		close()
		t.Fatal("overprivileged pool admitted")
	}
	if _, err = admin.Exec("REVOKE UPDATE(balance) ON public.users FROM s2_execution_reserve"); err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{"s2_execution_complete", "s2_execution_result_read"} {
		if _, err = admin.Exec("GRANT UPDATE(balance) ON public.users TO " + role); err != nil {
			t.Fatal(err)
		}
		write()
		if _, close, err := metonentry.Open(configPath, keys, groups); err == nil {
			close()
			t.Fatal("completion pool inherited direct balance write", role)
		}
		if _, err = admin.Exec("REVOKE UPDATE(balance) ON public.users FROM " + role); err != nil {
			t.Fatal(err)
		}
	}
}
