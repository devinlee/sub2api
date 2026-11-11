//go:build meton_managed && dispatch_integration && unit

package server

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	"github.com/Wei-Shaw/sub2api/ent"
	_ "github.com/Wei-Shaw/sub2api/ent/runtime"
	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/pkg/openai_compat"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/server/routes"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"github.com/redis/go-redis/v9"
)

type metonRouteFixture struct {
	Context metondispatch.Context
	Key     metonledger.SessionKey
	Secret  string
}

func routeDB(t *testing.T, role string) *sql.DB {
	t.Helper()
	db, err := sql.Open("postgres", "host=127.0.0.1 port=5432 dbname=s2_grants sslmode=disable user="+role)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

/** 实际注册路由、原生账户仓储／调度及 Redis 并发与同一来源账本组合，不替换文本 Handler。 */
func TestMetonManagedNativeRoutesPostgres(t *testing.T) {
	nativeRoutes(t, false)
}

/** 同一原生四路转换读取真实观察并结算；HTTP 错误保留 H，重复入站不再次发送。 */
func TestMetonManagedCompletionRoutesPostgres(t *testing.T) {
	nativeRoutes(t, true)
}

func nativeRoutes(t *testing.T, completion bool) {
	for key, value := range map[string]string{"FUNDS_MODE": "s2-source-v1", "ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "ISSUE_KEY_ID": strings.Repeat("3", 24), "INSPECT_KEY_ID": strings.Repeat("4", 24)} {
		t.Setenv("METON_MANAGED_"+key, value)
	}
	gin.SetMode(gin.TestMode)
	var fixtures []metonRouteFixture
	fixtureName := "METON_NATIVE_ROUTE_FIXTURE"
	if completion {
		fixtureName = "METON_COMPLETION_ROUTE_FIXTURE"
	}
	raw, err := os.ReadFile(os.Getenv(fixtureName))
	if err != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 6 {
		t.Fatal("missing native route fixture")
	}
	authDB, admin := routeDB(t, "s2_entry_auth"), routeDB(t, "postgres")
	client := ent.NewClient(ent.Driver(entsql.OpenDB(dialect.Postgres, authDB)))
	keyRepo := repository.NewAPIKeyRepository(client, authDB)
	groups := repository.NewGroupRepository(client, authDB)
	accounts := repository.NewAccountRepository(client, authDB, nil)
	keys := service.NewAPIKeyService(keyRepo, nil, nil, nil, nil, nil, nil)
	defer keys.StopAuthCacheInvalidationSubscriber()
	reserve, err := metonledger.NewTextLedger(routeDB(t, "s2_execution_reserve"))
	if err != nil {
		t.Fatal(err)
	}
	send, err := metonledger.NewTextLedger(routeDB(t, "s2_execution_send"))
	if err != nil {
		t.Fatal(err)
	}
	complete, err := metonledger.NewTextLedger(routeDB(t, "s2_execution_complete"))
	if err != nil {
		t.Fatal(err)
	}
	inspect, err := metonledger.NewTextLedger(routeDB(t, "s2_execution_result_read"))
	if err != nil {
		t.Fatal(err)
	}
	cache := redis.NewClient(&redis.Options{Addr: "127.0.0.1:6379"})
	defer cache.Close()
	if err = cache.Ping(t.Context()).Err(); err != nil {
		t.Fatal("isolated Redis unavailable", err)
	}
	concurrencyCache := repository.NewConcurrencyCache(cache, 5, 30)
	concurrency := service.NewConcurrencyService(concurrencyCache)
	signer := dispatchtest.New(t)
	for i, scenario := range []struct {
		original, wire string
		status         int
	}{
		{"responses", "responses", 200}, {"responses", "chat_completions", 200}, {"chat_completions", "chat_completions", 200}, {"chat_completions", "responses", 200},
		{"responses", "responses", 503}, {"chat_completions", "chat_completions", 503},
	} {
		name := scenario.original + "-" + scenario.wire
		if scenario.status != 200 {
			name += "-error"
		}
		t.Run(name, func(t *testing.T) {
			f := fixtures[i]
			var calls atomic.Int32
			var sentDigest atomic.Value
			path, wirePath := "/v1/responses", "/v1/responses"
			if scenario.original == "chat_completions" {
				path = "/v1/chat/completions"
			}
			if scenario.wire == "chat_completions" {
				wirePath = "/v1/chat/completions"
			}
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				body, _ := io.ReadAll(r.Body)
				sentDigest.Store(dispatchtest.Hash(body))
				if r.URL.Path != wirePath {
					t.Error("wrong native upstream path", r.URL.Path)
				}
				if r.Header.Get(metondispatch.ProofHeader) != "" || r.Header.Get(metondispatch.ContextHeader) != "" {
					t.Error("internal proof leaked")
				}
				w.Header().Set("Content-Type", "application/json")
				if scenario.status != 200 {
					w.WriteHeader(scenario.status)
					_, _ = io.WriteString(w, `{"error":{"message":"synthetic unavailable","type":"server_error"}}`)
					return
				}
				if scenario.wire == "chat_completions" {
					if completion {
						_, _ = io.WriteString(w, `{"id":"chat-route","object":"chat.completion","model":"meton-s2-text-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"你好，完成一次调用。","annotations":[],"tool_calls":[{"id":"call-route","type":"function","function":{"name":"read_fixture","arguments":"{\"city\":\"苏州\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"prompt_tokens_details":{"cached_tokens":0}}}`)
						return
					}
					_, _ = io.WriteString(w, `{"id":"chat-route","object":"chat.completion","model":"meton-s2-text-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"synthetic"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
					return
				}
				response := `{"id":"resp-route","object":"response","status":"completed","model":"meton-s2-text-fixture","output":[{"id":"msg-route","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"synthetic","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}`
				if completion {
					response = `{"id":"resp-route","object":"response","status":"completed","model":"meton-s2-text-fixture","output":[{"id":"msg-route","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"你好，完成一次调用。","annotations":[]}]},{"id":"fc-route","type":"function_call","status":"completed","call_id":"call-route","name":"read_fixture","arguments":"{\"city\":\"苏州\"}"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2,"input_tokens_details":{"cached_tokens":0}}}`
				}
				var request struct {
					Stream bool `json:"stream"`
				}
				if json.Unmarshal(body, &request) != nil {
					t.Error("invalid body")
				}
				if request.Stream {
					w.Header().Set("Content-Type", "text/event-stream")
					_, _ = io.WriteString(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":"+response+"}\n\n")
				} else {
					_, _ = io.WriteString(w, response)
				}
			}))
			defer upstream.Close()
			var group int64
			groupName := "native-route-" + name
			if completion {
				groupName = "completion-route-" + name
			}
			if err := admin.QueryRow("INSERT INTO groups(name,platform,status,subscription_type) VALUES($1,'openai','active','standard') RETURNING id", groupName).Scan(&group); err != nil {
				t.Fatal(err)
			}
			mode := openai_compat.ResponsesSupportModeForceResponses
			if scenario.wire == "chat_completions" {
				mode = openai_compat.ResponsesSupportModeForceChatCompletions
			}
			var accountIDs []int64
			for n := 0; n < 2; n++ {
				credentials, _ := json.Marshal(map[string]any{"api_key": "synthetic-provider", "base_url": upstream.URL})
				extra, _ := json.Marshal(map[string]any{openai_compat.ExtraKeyResponsesMode: string(mode)})
				var account int64
				if err := admin.QueryRow("INSERT INTO accounts(name,platform,type,status,schedulable,concurrency,priority,credentials,extra) VALUES('native-fixture','openai','apikey','active',true,4,$1,$2,$3) RETURNING id", n, string(credentials), string(extra)).Scan(&account); err != nil {
					t.Fatal(err)
				}
				if _, err := admin.Exec("INSERT INTO account_groups(account_id,group_id,priority) VALUES($1,$2,$3)", account, group, n); err != nil {
					t.Fatal(err)
				}
				accountIDs = append(accountIDs, account)
			}
			// 默认原生调度从实际仓储读取两个账户；错误后也不允许借备用账户重新发出原请求。
			profile, err := metonexecution.NewFixtureProfile(metonexecution.Spec{Version: "native-route-v1", Protocol: scenario.original, Model: "meton-s2-text-fixture",
				WireProtocol: scenario.wire, WireModel: "meton-s2-text-fixture", Target: upstream.URL + wirePath, MaxBodyBytes: 256 * 1024, InputWindow: 1024, OutputWindow: 128})
			if err != nil {
				t.Fatal(err)
			}
			entry, err := metonentry.New(signer.Verifier, keys, groups, reserve, send, complete, inspect, []metonentry.Route{{Group: group, Profiles: []*metonexecution.Profile{profile}}})
			if err != nil {
				t.Fatal(err)
			}
			cfg := &config.Config{Security: config.SecurityConfig{URLAllowlist: config.URLAllowlistConfig{AllowInsecureHTTP: true}}}
			billing := service.NewBillingCacheService(nil, nil, nil, nil, nil, nil, cfg, nil)
			defer billing.Stop()
			pool := repository.NewHTTPUpstream(cfg)
			gateway := service.NewOpenAIGatewayService(accounts, nil, nil, nil, nil, nil, repository.NewGatewayCache(cache), cfg, nil, concurrency,
				service.NewBillingService(cfg, nil), nil, billing, pool, nil, nil, nil, nil, nil, nil, nil, nil)
			defer gateway.CloseOpenAIWSPool()
			h := handler.NewOpenAIGatewayHandler(gateway, concurrency, billing, keys, nil, nil, nil, nil, cfg)
			router := gin.New()
			router.RedirectTrailingSlash = false
			router.RedirectFixedPath = false
			router.Use(metonManagedIngress(metonIngressOptions{models: true}))
			routes.RegisterGatewayRoutes(router, &handler.Handlers{OpenAIGateway: h, MetonText: middleware.MetonTextAuth(entry)}, nil, keys, nil, nil, nil, nil, cfg)
			var forbidden atomic.Int32
			for _, p := range []string{"/api/v1/admin/users/1/balance", "/api/v1/payment/orders", "/v1/images/generations", "/responses", "/v1/responses/alias"} {
				router.POST(p, func(c *gin.Context) { forbidden.Add(1); c.Status(200) })
			}
			source := httptest.NewServer(router)
			defer source.Close()
			body := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic","stream":false}`)
			if scenario.original == "chat_completions" {
				body = []byte(`{"model":"meton-s2-text-fixture","messages":[{"role":"user","content":"synthetic"}],"stream":false}`)
			}
			c := f.Context
			c.Protocol = scenario.original
			c.InputDigest = dispatchtest.Hash(body)
			c.ValidUntilMS = time.Now().Add(25 * time.Second).UnixMilli()
			header, proof := signer.Encode(t, c, path, time.Now())
			invoke := func(path string, header, proof, secret string) int {
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
				defer response.Body.Close()
				actual, e := io.ReadAll(response.Body)
				if completion && response.StatusCode == 200 && (e != nil || !bytes.Contains(actual, []byte("你好")) || !bytes.Contains(actual, []byte("read_fixture")) || !bytes.Contains(actual, []byte("苏州"))) {
					t.Error("native conversion lost text or function arguments", e)
				}
				return response.StatusCode
			}
			var successful atomic.Int32
			var wait sync.WaitGroup
			for n := 0; n < 8; n++ {
				wait.Add(1)
				go func() {
					defer wait.Done()
					if invoke(path, header, proof, f.Secret) == 200 {
						successful.Add(1)
					}
				}()
			}
			wait.Wait()
			want := int32(0)
			if scenario.status == 200 {
				want = 1
			}
			if calls.Load() != 1 || successful.Load() != want {
				t.Fatalf("native route network=%d successes=%d", calls.Load(), successful.Load())
			}
			var count int
			var quote, digest, state string
			if err := admin.QueryRow(`SELECT count(*),max(r.quote)::text,max(x.spec->>'body_digest'),max(d.state) FROM meton_ledger.text_requests r JOIN meton_ledger.text_executions x USING(request_id) JOIN meton_ledger.text_send_decisions d USING(request_id) WHERE r.operation_id=$1`, c.OperationID).Scan(&count, &quote, &digest, &state); err != nil {
				t.Fatal(err)
			}
			if count != 1 || quote != "1152.00000000" || digest != sentDigest.Load() || state != "dispatch_claimed" {
				t.Fatalf("original hold count=%d quote=%s state=%s digest=%v", count, quote, state, digest == sentDigest.Load())
			}
			// 结算完成与客户端返回存在先后；查询只找这一份原请求，不重放网络。
			var marker, requestID string
			if err := admin.QueryRow("SELECT source_marker::text,request_id::text FROM meton_ledger.text_requests WHERE operation_id=$1", c.OperationID).Scan(&marker, &requestID); err != nil {
				t.Fatal(err)
			}
			origin := metonfee.Origin{Environment: c.Environment, Source: c.Source, User: c.User, Account: c.Account, SourceMarker: marker, Caller: c.Caller, OperationID: c.OperationID, SourceRequestID: requestID}
			var result *metonledger.ExecutionResult
			until := time.Now().Add(3 * time.Second)
			for {
				result, err = inspect.FindExecution(t.Context(), origin)
				if err == nil || time.Now().After(until) {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if err != nil {
				t.Fatal("missing original response observation", err)
			}
			if completion && scenario.status == 200 {
				if !result.Observation.FeeReady || result.Observation.Execution != "completed" || result.Posting == nil || result.Posting.Report.Item.Amount != "2.00000000" || result.Ending == nil {
					t.Fatal("known response fee not settled", result)
				}
			} else if result.Observation.FeeReady || result.Posting != nil || result.Ending != nil {
				t.Fatal("missing or failed response usage invented a fee", result)
			}
			old := c
			old.ValidUntilMS = time.Now().Add(-time.Second).UnixMilli()
			old.OperationID = uuid.NewString()
			oldHeader, oldProof := signer.Encode(t, old, path, time.Now())
			if invoke(path, oldHeader, oldProof, f.Secret) != 403 || invoke(path, header, proof, fixtures[(i+1)%6].Secret) != 403 {
				t.Fatal("expired sender or foreign key admitted")
			}
			for _, p := range []string{"/api/v1/admin/users/1/balance", "/api/v1/payment/orders", "/v1/images/generations", "/responses", "/v1/responses/alias", path + "?alias=1"} {
				if invoke(p, header, proof, f.Secret) != 403 {
					t.Fatal("native effect route opened", p)
				}
			}
			if forbidden.Load() != 0 || calls.Load() != 1 {
				t.Fatal("retry or native write escaped source boundary")
			}
			var remote int64
			if err := admin.QueryRow("SELECT user_id FROM api_keys WHERE id=$1", f.Key.ID).Scan(&remote); err != nil {
				t.Fatal(err)
			}
			if slots, err := concurrencyCache.GetUserConcurrency(t.Context(), remote); err != nil || slots != 0 {
				t.Fatalf("user slots retained: %d %v", slots, err)
			}
			for _, id := range accountIDs {
				if slots, err := concurrencyCache.GetAccountConcurrency(t.Context(), id); err != nil || slots != 0 {
					t.Fatalf("account slots retained: %d %v", slots, err)
				}
			}
		})
	}
}
