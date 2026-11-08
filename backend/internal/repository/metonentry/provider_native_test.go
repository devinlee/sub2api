//go:build meton_managed && dispatch_integration && provider_integration && unit

package metonentry_test

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	"github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/pkg/openai_compat"
	native "github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

/** 新接缝沿实际来源鉴权、原生转发和连接池保存供应绑定；断流后只读取原供应结果。 */
func TestProviderNativeOriginalResult(t *testing.T) {
	environment(t)
	gin.SetMode(gin.TestMode)
	var fixtures []entryFixture
	raw, e := os.ReadFile(os.Getenv("METON_PROVIDER_NATIVE_FIXTURE"))
	if e != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 3 {
		t.Fatal("缺本轮隔离输入", e)
	}
	auth, admin := connection(t, "s2_entry_auth"), connection(t, "postgres")
	client := ent.NewClient(ent.Driver(entsql.OpenDB(dialect.Postgres, auth)))
	keys := service.NewAPIKeyService(native.NewAPIKeyRepository(client, auth), nil, nil, nil, nil, nil, nil)
	t.Cleanup(keys.StopAuthCacheInvalidationSubscriber)
	groups := native.NewGroupRepository(client, auth)
	accounts := native.NewAccountRepository(client, auth, nil)
	read := ledger(t, connection(t, "s2_provider_read"))
	observer := ledger(t, connection(t, "s2_resolution_observe"))
	executor := ledger(t, connection(t, "s2_resolution_apply"))
	var posts, gets atomic.Int32
	var mode, providerKey, responseID string
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+providerKey {
			t.Error("实际供应身份改变")
			w.WriteHeader(403)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/v1/responses" {
			posts.Add(1)
			body, e := io.ReadAll(r.Body)
			if e != nil {
				t.Error(e)
			}
			var input map[string]any
			if json.Unmarshal(body, &input) != nil {
				t.Error("最终正文无效")
			}
			stored, present := input["store"]
			if mode == "not_stored" {
				if !present || stored != false {
					t.Error("原存储设置被改写")
				}
			} else if present {
				t.Error("原默认存储被改写")
			}
			// 提供原响应身份后故意断流，首次观察必须是已派发未知，而非测试直接插入未知。
			w.Header().Set("Content-Type", "text/event-stream")
			w.Header().Set("Content-Length", "9999")
			_, _ = io.WriteString(w, "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\""+responseID+"\",\"model\":\"meton-s2-text-fixture\",\"status\":\"in_progress\",\"output\":[]}}\n\n")
			return
		}
		if r.Method == "GET" && r.URL.Path == "/v1/responses/"+responseID {
			gets.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"id":"`+responseID+`","model":"meton-s2-text-fixture","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2,"input_tokens_details":{"cached_tokens":0}}}`)
			return
		}
		t.Error("来源发送了其他方法或路径")
		w.WriteHeader(400)
	}))
	defer upstream.Close()
	dir := t.TempDir()
	ca := filepath.Join(dir, "upstream-ca.pem")
	if e = os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: upstream.Certificate().Raw}), 0600); e != nil {
		t.Fatal(e)
	}
	// 仍做正式证书校验；只给这个隔离进程增加夹具 CA，不使用跳过校验。
	t.Setenv("SSL_CERT_FILE", ca)
	t.Setenv("SSL_CERT_DIR", dir)
	cfg := &config.Config{Security: config.SecurityConfig{URLAllowlist: config.URLAllowlistConfig{AllowPrivateHosts: true}}}
	pool := native.NewHTTPUpstream(cfg)
	svc := service.NewOpenAIGatewayService(nil, nil, nil, nil, nil, nil, nil, cfg, nil, nil, nil, nil, nil, pool, nil, nil, nil, nil, nil, nil, nil, nil)
	defer svc.CloseOpenAIWSPool()
	supplierClient := upstream.Client()
	transport := supplierClient.Transport.(*http.Transport).Clone()
	transport.TLSClientConfig = transport.TLSClientConfig.Clone()
	roots := x509.NewCertPool()
	roots.AddCert(upstream.Certificate())
	transport.TLSClientConfig.RootCAs = roots
	transport.TLSClientConfig.InsecureSkipVerify = false
	reader, e := metonprovider.NewReader(&http.Client{Transport: transport}, []string{upstream.URL + "/v1/responses"}, 1, 3*time.Second)
	if e != nil {
		t.Fatal(e)
	}
	defer reader.Close()
	signer := dispatchtest.New(t)
	cert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: signer.Certificate.Raw})
	if e = os.WriteFile(filepath.Join(dir, "gateway.pem"), cert, 0600); e != nil {
		t.Fatal(e)
	}
	for name, role := range map[string]string{"reserve": "s2_provider_reserve", "send": "s2_provider_send", "complete": "s2_provider_complete", "inspect": "s2_provider_inspect"} {
		if e = os.WriteFile(filepath.Join(dir, name+".dsn"), []byte("host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role), 0600); e != nil {
			t.Fatal(e)
		}
	}
	evidence := []map[string]any{}
	for i, nextMode := range []string{"retained", "not_stored", "credentials_changed"} {
		t.Run(nextMode, func(t *testing.T) {
			mode = nextMode
			providerKey = "isolated-provider-" + mode
			responseID = "resp_" + mode
			f := fixtures[i]
			postBefore, getBefore := posts.Load(), gets.Load()
			creds, _ := json.Marshal(map[string]any{"api_key": providerKey, "base_url": upstream.URL})
			extra, _ := json.Marshal(map[string]any{openai_compat.ExtraKeyResponsesMode: string(openai_compat.ResponsesSupportModeForceResponses)})
			var accountID int64
			e = admin.QueryRow("INSERT INTO accounts(name,platform,type,credentials,extra,status,concurrency,priority) VALUES($1,'openai','apikey',$2,$3,'active',1,1) RETURNING id", "provider-"+mode, string(creds), string(extra)).Scan(&accountID)
			if e != nil {
				t.Fatal("隔离供应账户", e)
			}
			account, e := accounts.GetByID(t.Context(), accountID)
			if e != nil {
				t.Fatal("实际供应账户仓储", e)
			}
			configBody := map[string]any{"format_version": 2, "capture_provider": true, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1,
				"gateways": map[string]string{"gateway-s2": "gateway.pem"}, "reserve_dsn_file": "reserve.dsn", "send_dsn_file": "send.dsn", "complete_dsn_file": "complete.dsn", "inspect_dsn_file": "inspect.dsn",
				"routes": []any{map[string]any{"group": f.Group, "profiles": []any{map[string]any{"version": "provider-native-v1", "protocol": "responses", "model": "meton-s2-text-fixture", "wire_protocol": "responses", "wire_model": "meton-s2-text-fixture", "target": upstream.URL + "/v1/responses", "max_body_bytes": 262144, "input_window": 2, "output_window": 1}}}}}
			conf, _ := json.Marshal(configBody)
			path := filepath.Join(dir, "entry.json")
			if e = os.WriteFile(path, conf, 0600); e != nil {
				t.Fatal(e)
			}
			entry, close, e := metonentry.Open(path, keys, groups)
			if e != nil {
				t.Fatal("正式配置未装配", e)
			}
			defer close()
			body := []byte(`{"model":"meton-s2-text-fixture","input":"isolated","stream":true}`)
			if mode == "not_stored" {
				body = []byte(`{"model":"meton-s2-text-fixture","input":"isolated","stream":true,"store":false}`)
			}
			c := f.Context
			c.InputDigest = dispatchtest.Hash(body)
			c.ValidUntilMS = time.Now().Add(25 * time.Second).UnixMilli()
			header, proof := signer.Encode(t, c, "/v1/responses", time.Now())
			router := gin.New()
			router.POST("/v1/responses", middleware.MetonTextAuth(entry), func(g *gin.Context) {
				key, ok := middleware.GetAPIKeyFromContext(g)
				if !ok || key.ID != f.Key.ID {
					t.Error("原账户鉴权不符")
					g.Status(403)
					return
				}
				actual, _ := io.ReadAll(g.Request.Body)
				_, err := svc.Forward(g.Request.Context(), g, account, actual)
				if err != nil && !g.Writer.Written() {
					g.Status(502)
				}
			})
			source := httptest.NewServer(router)
			defer source.Close()
			invoke := func() int {
				request, _ := http.NewRequestWithContext(t.Context(), "POST", source.URL+"/v1/responses", bytes.NewReader(body))
				request.Header.Set("Content-Type", "application/json")
				request.Header.Set("Authorization", "Bearer "+f.Secret)
				request.Header.Set(metondispatch.ContextHeader, header)
				request.Header.Set(metondispatch.ProofHeader, proof)
				response, err := http.DefaultClient.Do(request)
				if err != nil {
					t.Fatal(err)
				}
				_, _ = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
				return response.StatusCode
			}
			invoke()
			if posts.Load() != postBefore+1 {
				t.Fatal("没有实际且唯一的原生发送", posts.Load()-postBefore)
			}
			var origin metonfee.Origin
			var requestID, marker string
			e = admin.QueryRow("SELECT request_id::text,source_marker::text FROM meton_ledger.text_requests WHERE operation_id=$1 AND caller=$2", c.OperationID, c.Caller).Scan(&requestID, &marker)
			if e != nil {
				t.Fatal("原请求未保存", e)
			}
			origin = metonfee.Origin{Environment: c.Environment, Source: c.Source, User: c.User, Account: c.Account, SourceMarker: marker, Caller: c.Caller, OperationID: c.OperationID, SourceRequestID: requestID}
			material, e := read.FindProviderOriginal(t.Context(), origin)
			if e != nil || material.Binding.Account != accountID || material.Observation.Execution != "unknown" || material.Observation.ResponseID != responseID {
				t.Fatal("原生观察／供应绑定不符", e)
			}
			if invoke() == 200 || posts.Load() != postBefore+1 {
				t.Fatal("原重放触发第二次生成")
			}
			if _, e = admin.Exec("UPDATE api_keys SET status='inactive' WHERE id=$1", f.Key.ID); e != nil {
				t.Fatal(e)
			}
			if mode == "credentials_changed" {
				if _, e = admin.Exec("UPDATE accounts SET credentials=jsonb_set(credentials,'{api_key}','\"isolated-rotated\"'::jsonb),updated_at=clock_timestamp() WHERE id=$1", accountID); e != nil {
					t.Fatal(e)
				}
			}
			evidenceID := uuid.NewString()
			observed, e := read.ObserveProvider(t.Context(), origin, evidenceID, reader, metonentry.ProviderCredentials(accounts), observer, func(_ context.Context) error { return nil })
			wantBalance, wantH, wantFees := "5.00000000", "3.00000000", 0
			if mode == "retained" {
				if e != nil || observed == nil || gets.Load() != getBefore+1 {
					t.Fatal("原生绑定不能恢复结果", e)
				}
				execute := metonledger.ResultResolutionKey{EvidenceID: evidenceID, CaseID: uuid.NewString(), AttemptID: uuid.NewString(), ApprovalDigest: strings.Repeat("f", 64)}
				receipt, e := executor.ApplyResultProof(t.Context(), origin, execute)
				if e != nil || receipt.Result.Posting.Funded != "2.00000000" {
					t.Fatal("原生结果没有唯一结算", e)
				}
				if _, e = executor.ApplyResultProof(t.Context(), origin, execute); e != nil {
					t.Fatal(e)
				}
				wantBalance, wantH, wantFees = "3.00000000", "0.00000000", 1
			} else if e == nil || gets.Load() != getBefore {
				t.Fatal("不可检索的原生请求仍访问供应", e)
			}
			var balance, held string
			var feeCount, active int
			e = admin.QueryRow(`SELECT sum(l.remaining)::text,sum(l.held)::text FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=$1`, marker).Scan(&balance, &held)
			if e != nil {
				t.Fatal(e)
			}
			e = admin.QueryRow("SELECT (SELECT count(*) FROM meton_ledger.text_fee_reports WHERE request_id=$1),(SELECT count(*) FROM api_keys WHERE id=$2 AND status='active')", requestID, f.Key.ID).Scan(&feeCount, &active)
			if e != nil || balance != wantBalance || held != wantH || feeCount != wantFees || active != 0 {
				t.Fatal("原生资金或凭据异常", balance, held, feeCount, active, e)
			}
			evidence = append(evidence, map[string]any{"mode": mode, "origin": origin, "provider_account": accountID, "query_kind": material.Binding.QueryKind, "post_count": posts.Load() - postBefore, "get_count": gets.Load() - getBefore, "balance": balance, "held": held, "fee_count": feeCount, "old_key_active": active})
		})
	}
	if !t.Failed() {
		wire, _ := json.Marshal(evidence)
		if e = os.WriteFile(os.Getenv("METON_PROVIDER_NATIVE_EXPORT"), wire, 0600); e != nil {
			t.Fatal(e)
		}
	}
}
