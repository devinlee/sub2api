//go:build meton_managed && dispatch_integration && unit

package server

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	"github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
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
	"github.com/redis/go-redis/v9"
)

type jointRecorded struct {
	path    string
	body    []byte
	headers http.Header
}
type jointOrigin struct {
	User, Account, Creation, Dispatch string
	Remote                            int64
	Marker                            string
}
type jointFixture struct {
	desktopMode   bool
	resultMode    bool
	controlMode   bool
	controlState  *jointControlState
	t             *testing.T
	admin, grants *sql.DB
	env           string
	router        *gin.Engine
	mu            sync.Mutex
	origins       map[string]jointOrigin
	seen          map[string]jointRecorded
	calls         map[string]int
	arrivals      map[string]int
	claims        map[string]*jointClaimGate
	disconnected  map[string]int
	gates         map[string]chan struct{}
	lock          *sql.Tx
	finished      chan struct{}
}

/** 测试控制面只编译进本用例，且只在本轮隔离网络和随机口令下使用；生产入口没有这些路由。 */
func TestMetonManagedGatewayJoint(t *testing.T) {
	gin.SetMode(gin.TestMode)
	directory := os.Getenv("METON_JOINT_OUTPUT")
	secret, err := os.ReadFile(filepath.Join(directory, "control.key"))
	if err != nil || len(secret) != 64 {
		t.Fatal("missing joint control key")
	}
	f := &jointFixture{t: t, desktopMode: os.Getenv("METON_DESKTOP_JOINT") == "1", resultMode: os.Getenv("METON_RESULT_JOINT") == "1", controlMode: os.Getenv("METON_CONTROL_JOINT") == "1", controlState: newJointControlState(), admin: jointDB(t, "postgres"), grants: jointDB(t, "s2_app"), origins: map[string]jointOrigin{},
		seen: map[string]jointRecorded{}, calls: map[string]int{}, arrivals: map[string]int{}, claims: map[string]*jointClaimGate{}, disconnected: map[string]int{}, gates: map[string]chan struct{}{}, finished: make(chan struct{})}
	upstream := httptest.NewServer(http.HandlerFunc(f.upstream))
	defer upstream.Close()
	mux := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/__fixture/") {
			if r.Method != "POST" || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), append([]byte("Bearer "), secret...)) != 1 {
				w.WriteHeader(403)
				return
			}
			f.control(w, r, upstream.URL)
			return
		}
		f.mu.Lock()
		router := f.router
		f.mu.Unlock()
		if router == nil {
			w.WriteHeader(503)
			return
		}
		body, readErr := io.ReadAll(io.LimitReader(r.Body, 256*1024+1))
		if readErr != nil || len(body) > 256*1024 {
			w.WriteHeader(400)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		contextBytes, _ := base64.RawURLEncoding.DecodeString(r.Header.Get(metondispatch.ContextHeader))
		var c struct {
			Operation string `json:"operation_id"`
		}
		if json.Unmarshal(contextBytes, &c) == nil && c.Operation != "" {
			f.mu.Lock()
			f.arrivals[c.Operation]++
			if _, exists := f.seen[c.Operation]; !exists {
				f.seen[c.Operation] = jointRecorded{r.URL.Path, body, r.Header.Clone()}
			}
			f.mu.Unlock()
		}
		if !f.controlMode || !f.executionResponse(w, r, router) {
			router.ServeHTTP(w, r)
		}
	})
	listener, err := net.Listen("tcp4", "0.0.0.0:9443")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(mux)
	server.Listener = listener
	server.StartTLS()
	defer server.Close()
	pin := sha256.Sum256(server.Certificate().Raw)
	ready, _ := json.Marshal(map[string]any{"format_version": 1, "pin": hex.EncodeToString(pin[:])})
	if err = os.WriteFile(filepath.Join(directory, "ready.json"), ready, 0600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-f.finished:
	case <-time.After(15 * time.Minute):
		t.Error("joint peer did not complete")
	}
	f.mu.Lock()
	for _, gate := range f.gates {
		close(gate)
	}
	f.gates = map[string]chan struct{}{}
	for operation, gate := range f.claims {
		close(gate.release)
		delete(f.claims, operation)
	}
	if f.lock != nil {
		_ = f.lock.Rollback()
		f.lock = nil
	}
	f.mu.Unlock()
	f.stopExecutionControls()
}

/** 连接地址固定为专属测试网络别名，不能接受原服务的端口或任意 DSN。 */
func jointDB(t *testing.T, role string) *sql.DB {
	t.Helper()
	db, err := sql.Open("postgres", "host=source-db port=5432 dbname=s2_grants sslmode=disable user="+role)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func (f *jointFixture) control(w http.ResponseWriter, r *http.Request, upstream string) {
	var c struct {
		Environment, Certificate, User, Account, Creation, Dispatch, Operation, Mode, Foreign string
		Claim                                                                                 json.RawMessage
	}
	d := json.NewDecoder(io.LimitReader(r.Body, 32768))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil {
		w.WriteHeader(400)
		return
	}
	var value any = map[string]bool{"ok": true}
	var err error
	switch r.URL.Path {
	case "/__fixture/setup":
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.router != nil {
			err = errors.New("already configured")
			break
		}
		if f.desktopMode && c.Environment != "s1-isolated" || !f.desktopMode && !regexp.MustCompile(`^model-token-[a-f0-9]{32}$`).MatchString(c.Environment) {
			err = errors.New("invalid fixture environment")
			break
		}
		var certificate []byte
		certificate, err = base64.StdEncoding.DecodeString(c.Certificate)
		if err == nil {
			err = f.setup(c.Environment, certificate, upstream)
		}
	case "/__fixture/account":
		var origin jointOrigin
		origin, err = f.account(c.User, c.Account, c.Creation, c.Dispatch)
		value = origin
	case "/__fixture/key":
		value, err = f.key(c.Claim)
	case "/__fixture/state":
		value, err = f.state(c.User, c.Operation, c.Mode)
	case "/__fixture/control-mode", "/__fixture/control-state", "/__fixture/release-control":
		value, err = f.executionFixture(r.URL.Path, c.Operation, c.Mode)
	case "/__fixture/pause-claim":
		f.mu.Lock()
		if _, exists := f.claims[c.Operation]; exists {
			err = errors.New("duplicate claim gate")
		} else {
			f.claims[c.Operation] = &jointClaimGate{release: make(chan struct{})}
		}
		f.mu.Unlock()
	case "/__fixture/release-claim":
		f.mu.Lock()
		if gate := f.claims[c.Operation]; gate != nil {
			close(gate.release)
			delete(f.claims, c.Operation)
		}
		f.mu.Unlock()
	case "/__fixture/cancel-source":
		value, err = f.cancelSource(r.Context(), c.User, c.Operation)
	case "/__fixture/release":
		f.mu.Lock()
		if gate := f.gates[c.Mode]; gate != nil {
			close(gate)
			delete(f.gates, c.Mode)
		}
		f.mu.Unlock()
	case "/__fixture/lock":
		f.mu.Lock()
		defer f.mu.Unlock()
		origin, ok := f.origins[c.User]
		if !ok || f.lock != nil {
			err = errors.New("invalid account lock")
			break
		}
		// 锁跨两个独立控制请求保留；不能绑定本请求的取消，否则响应结束就会自动回滚。
		f.lock, err = f.admin.Begin()
		if err == nil {
			_, err = f.lock.ExecContext(r.Context(), "SELECT id FROM users WHERE id=$1 FOR UPDATE", origin.Remote)
		}
	case "/__fixture/unlock":
		f.mu.Lock()
		if f.lock != nil {
			err = f.lock.Rollback()
			f.lock = nil
		}
		f.mu.Unlock()
	case "/__fixture/replay":
		f.mu.Lock()
		original, ok := f.seen[c.Operation]
		other, foreign := f.seen[c.Foreign]
		router := f.router
		f.mu.Unlock()
		if !ok || router == nil {
			err = errors.New("unknown original")
			break
		}
		request := httptest.NewRequest("POST", original.path, bytes.NewReader(original.body))
		request.Header = original.headers.Clone()
		if c.Foreign != "" {
			if !foreign {
				err = errors.New("unknown other owner")
				break
			}
			request.Header.Set("Authorization", other.headers.Get("Authorization"))
		}
		response := httptest.NewRecorder()
		var proof struct{ IssuedAt, ExpiresAt int64 }
		proofErr := json.Unmarshal([]byte(original.headers.Get(metondispatch.ProofHeader)), &proof)
		now := time.Now().Unix()
		current := proofErr == nil && proof.IssuedAt <= now && now < proof.ExpiresAt
		router.ServeHTTP(response, request)
		value = map[string]any{"status": response.Code, "proofCurrent": current}
	case "/__fixture/finish":
		select {
		case <-f.finished:
		default:
			close(f.finished)
		}
	default:
		w.WriteHeader(404)
		return
	}
	if err != nil {
		f.t.Errorf("joint fixture %s: %v", r.URL.Path, err)
		http.Error(w, "fixture operation failed", 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

/** 初始化本轮空账号范围；已有旧测试样本不迁到新身份，所有调用均须匹配新的来源栅栏。 */
func (f *jointFixture) setup(env string, rawCertificate []byte, upstream string) error {
	certificate, err := x509.ParseCertificate(rawCertificate)
	if err != nil {
		return err
	}
	verifier, err := metondispatch.NewVerifier(env, f.sourceName(), 1, map[string]*x509.Certificate{f.serviceName(): certificate})
	if err != nil {
		return err
	}
	for key, value := range map[string]string{"FUNDS_MODE": "s2-source-v1", "ENVIRONMENT": env, "SOURCE": f.sourceName(), "EPOCH": "1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "ISSUE_KEY_ID": strings.Repeat("3", 24), "INSPECT_KEY_ID": strings.Repeat("4", 24)} {
		f.t.Setenv("METON_MANAGED_"+key, value)
	}
	if _, err = f.admin.Exec("UPDATE meton_managed_fence SET environment=$1,source=$2 WHERE singleton AND epoch=1", env, f.sourceName()); err != nil {
		return err
	}
	if _, err = f.admin.Exec("INSERT INTO meton_ledger.registration_rules VALUES($1,$2,'joint-grant-v1','sample-credit',1)", env, f.sourceName()); err != nil {
		return err
	}
	auth := jointDB(f.t, "s2_entry_auth")
	client := ent.NewClient(ent.Driver(entsql.OpenDB(dialect.Postgres, auth)))
	keys := service.NewAPIKeyService(repository.NewAPIKeyRepository(client, auth), nil, nil, nil, nil, nil, nil)
	f.t.Cleanup(keys.StopAuthCacheInvalidationSubscriber)
	groups := repository.NewGroupRepository(client, auth)
	accounts := repository.NewAccountRepository(client, auth, nil)
	reserve, err := metonledger.NewTextLedger(jointDB(f.t, "s2_execution_reserve"))
	if err != nil {
		return err
	}
	send, err := metonledger.NewTextLedger(f.claimDB())
	if err != nil {
		return err
	}
	complete, err := metonledger.NewTextLedger(jointDB(f.t, "s2_execution_complete"))
	if err != nil {
		return err
	}
	inspect, err := metonledger.NewTextLedger(jointDB(f.t, "s2_execution_result_read"))
	if err != nil {
		return err
	}
	cache := redis.NewClient(&redis.Options{Addr: "source-redis:6379"})
	f.t.Cleanup(func() { _ = cache.Close() })
	if err = cache.Ping(context.Background()).Err(); err != nil {
		return err
	}
	concurrency := service.NewConcurrencyService(repository.NewConcurrencyCache(cache, 5, 30))
	var selected []metonentry.Route
	version, rate, inputWindow, outputWindow := "joint-v1", 1000000, 2, 1
	if f.desktopMode {
		// 桌面要容纳真实工具声明；价格仍是零外部费用的合成单位，不能沿用小协议样本的 2/1 窗口。
		version, rate, inputWindow, outputWindow = "desktop-v1", 1, 30720, 2048
	}
	for _, protocol := range []string{"responses", "chat_completions"} {
		if _, err = f.admin.Exec("INSERT INTO meton_ledger.text_prices VALUES($1,$3,$2,'synthetic-text',$4,'sample-credit',$5,$5,$5,1,$6,$7);", env, protocol, f.sourceName(), version, rate, inputWindow, outputWindow); err != nil {
			return err
		}
		if _, err = f.admin.Exec("INSERT INTO meton_ledger.active_text_prices VALUES($1,$3,$2,'synthetic-text',$4)", env, protocol, f.sourceName(), version); err != nil {
			return err
		}
		var group int64
		if err = f.admin.QueryRow("INSERT INTO groups(name,platform,status,subscription_type) VALUES($1,'openai','active','standard') RETURNING id", "joint-"+protocol).Scan(&group); err != nil {
			return err
		}
		path, mode := "/v1/responses", openai_compat.ResponsesSupportModeForceResponses
		if protocol == "chat_completions" {
			path = "/v1/chat/completions"
			mode = openai_compat.ResponsesSupportModeForceChatCompletions
		}
		for n := 0; n < 2; n++ {
			credentials, _ := json.Marshal(map[string]string{"api_key": "synthetic-provider", "base_url": upstream})
			extra, _ := json.Marshal(map[string]string{openai_compat.ExtraKeyResponsesMode: string(mode)})
			var id int64
			if err = f.admin.QueryRow("INSERT INTO accounts(name,platform,type,status,schedulable,concurrency,priority,credentials,extra) VALUES('joint-fixture','openai','apikey','active',true,4,$1,$2,$3) RETURNING id", n, string(credentials), string(extra)).Scan(&id); err != nil {
				return err
			}
			if _, err = f.admin.Exec("INSERT INTO account_groups(account_id,group_id,priority) VALUES($1,$2,$3)", id, group, n); err != nil {
				return err
			}
		}
		// 窗口与同批价格固定；只用于零费用联验，不能作为生产模型价格或上限。
		profile, err := metonexecution.NewFixtureProfile(metonexecution.Spec{Version: version, Protocol: protocol, Model: "synthetic-text", WireProtocol: protocol,
			WireModel: "synthetic-text", Target: upstream + path, MaxBodyBytes: 256 * 1024, InputWindow: inputWindow, OutputWindow: outputWindow})
		if err != nil {
			return err
		}
		selected = append(selected, metonentry.Route{Group: group, Profiles: []*metonexecution.Profile{profile}})
	}
	entry, err := metonentry.New(verifier, keys, groups, reserve, send, complete, inspect, selected)
	if err != nil {
		return err
	}
	cfg := &config.Config{Security: config.SecurityConfig{URLAllowlist: config.URLAllowlistConfig{AllowInsecureHTTP: true}}}
	billing := service.NewBillingCacheService(nil, nil, nil, nil, nil, nil, cfg, nil)
	f.t.Cleanup(billing.Stop)
	pool := repository.NewHTTPUpstream(cfg)
	gateway := service.NewOpenAIGatewayService(accounts, nil, nil, nil, nil, nil, repository.NewGatewayCache(cache), cfg, nil, concurrency,
		service.NewBillingService(cfg, nil), nil, billing, pool, nil, nil, nil, nil, nil, nil, nil, nil)
	f.t.Cleanup(gateway.CloseOpenAIWSPool)
	h := handler.NewOpenAIGatewayHandler(gateway, concurrency, billing, keys, nil, nil, nil, nil, cfg)
	router := gin.New()
	router.RedirectTrailingSlash = false
	router.RedirectFixedPath = false
	router.Use(metonManagedIngress(metonIngressOptions{models: true}))
	routes.RegisterGatewayRoutes(router, &handler.Handlers{OpenAIGateway: h, MetonText: middleware.MetonTextAuth(entry)}, nil, keys, nil, nil, nil, nil, cfg)
	f.env = env
	f.router = router
	if f.resultMode {
		f.resultReads(router)
	}
	if f.controlMode {
		if err = f.executionRoutes(router, entry); err != nil {
			return err
		}
	}
	if f.desktopMode {
		f.desktopRoutes(router)
	}
	return nil
}

func (f *jointFixture) account(user, account, creation, dispatch string) (jointOrigin, error) {
	for _, id := range []string{user, account, creation, dispatch} {
		if _, err := uuid.Parse(id); err != nil {
			return jointOrigin{}, err
		}
	}
	if _, err := f.admin.Exec("SELECT meton_claim_managed_account($1,$6,1,$2,$3,$4,$5)", f.env, user, account, creation, dispatch, f.sourceName()); err != nil {
		return jointOrigin{}, err
	}
	o := jointOrigin{User: user, Account: account, Creation: creation, Dispatch: dispatch}
	if err := f.admin.QueryRow("SELECT remote_user,source_marker FROM meton_managed_creations WHERE operation=$1", creation).Scan(&o.Remote, &o.Marker); err != nil {
		return o, err
	}
	eligibility := uuid.NewString()
	if _, err := f.grants.Exec("SELECT meton_ledger.redeem_registration($1,$9,1,$2,$3,$4,$5,$6,$7,$8,'joint-grant-v1','sample-credit','5.00000000')", f.env, creation, user, account, dispatch, o.Remote, o.Marker, eligibility, f.sourceName()); err != nil {
		return o, err
	}
	f.mu.Lock()
	f.origins[user] = o
	f.mu.Unlock()
	return o, nil
}

func (f *jointFixture) key(claim json.RawMessage) (any, error) {
	var c struct{ Operation string }
	if json.Unmarshal(claim, &c) != nil {
		return nil, errors.New("invalid key claim")
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	material := "sk-" + hex.EncodeToString(secret)
	if _, err := f.admin.Exec("SELECT meton_issue_managed_key($1,$4,1,$2::jsonb,clock_timestamp()+interval '25 seconds',$3)", f.env, string(claim), material, f.sourceName()); err != nil {
		return nil, err
	}
	var id int64
	var created, expires time.Time
	var hash string
	if err := f.admin.QueryRow("SELECT remote_key,created_at,expires_at,material_sha256 FROM meton_managed_keys WHERE operation=$1", c.Operation).Scan(&id, &created, &expires, &hash); err != nil {
		return nil, err
	}
	return map[string]any{"key": material, "id": id, "created": created, "expires": expires, "hash": hash}, nil
}

func (f *jointFixture) state(user, operation, mode string) (any, error) {
	f.mu.Lock()
	origin, ok := f.origins[user]
	calls, disconnected := f.calls[mode], f.disconnected[mode]
	arrivals := f.arrivals[operation]
	claimWaiting := f.claims[operation] != nil && f.claims[operation].entered
	_, seen := f.seen[operation]
	f.mu.Unlock()
	if !ok {
		return nil, errors.New("unknown fixture user")
	}
	var balance, hold, quote, digest, decision string
	var count, executions, waiting int
	if err := f.admin.QueryRow("SELECT u.balance::text,(SELECT coalesce(sum(l.held),0)::numeric(20,8)::text FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=$1) FROM users u WHERE u.id=$2", origin.Marker, origin.Remote).Scan(&balance, &hold); err != nil {
		return nil, err
	}
	if err := f.admin.QueryRow(`SELECT count(*),coalesce(max(r.quote)::text,''),coalesce(max(r.input_digest),''),coalesce(max(d.state),''),count(x.request_id)
		FROM meton_ledger.text_requests r LEFT JOIN meton_ledger.text_send_decisions d USING(request_id) LEFT JOIN meton_ledger.text_executions x USING(request_id)
		WHERE r.source_marker=$1 AND r.operation_id=$2`, origin.Marker, operation).Scan(&count, &quote, &digest, &decision, &executions); err != nil {
		return nil, err
	}
	if err := f.admin.QueryRow("SELECT count(*) FROM pg_stat_activity WHERE usename='s2_execution_reserve' AND wait_event_type='Lock'").Scan(&waiting); err != nil {
		return nil, err
	}
	return map[string]any{"calls": calls, "disconnected": disconnected, "seen": seen, "balance": balance, "hold": hold, "requests": count, "executions": executions,
		"quote": quote, "inputDigest": digest, "decision": decision, "waiting": waiting, "arrivals": arrivals, "claimWaiting": claimWaiting}, nil
}

func (f *jointFixture) upstream(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Input    json.RawMessage
		Messages []struct {
			Role    string
			Content json.RawMessage
		}
		Tools  json.RawMessage
		Stream bool
	}
	if json.NewDecoder(r.Body).Decode(&b) != nil {
		w.WriteHeader(400)
		return
	}
	if f.desktopMode {
		f.desktopUpstream(w, r, b.Input, b.Messages, b.Tools, b.Stream)
		return
	}
	mode := jointText(b.Input)
	if len(b.Messages) > 0 {
		mode = jointText(b.Messages[0].Content)
	}
	if mode == "" {
		f.t.Error("missing synthetic upstream text")
		w.WriteHeader(400)
		return
	}
	if r.Header.Get(metondispatch.ContextHeader) != "" || r.Header.Get(metondispatch.ProofHeader) != "" {
		f.t.Error("joint source leaked proof")
		w.WriteHeader(500)
		return
	}
	f.mu.Lock()
	f.calls[mode]++
	var gate chan struct{}
	if strings.HasPrefix(mode, "gate-") {
		gate = make(chan struct{})
		f.gates[mode] = gate
	}
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-r.Context().Done():
			f.mu.Lock()
			f.disconnected[mode]++
			f.mu.Unlock()
			return
		}
	}
	if f.controlMode && strings.HasPrefix(mode, "streamgate-") {
		f.executionStream(w, r, mode)
		return
	}
	if strings.HasPrefix(mode, "error-") {
		http.Error(w, `{"error":{"type":"server_error"}}`, 503)
		return
	}
	if f.resultMode {
		f.resultUpstream(w, r, mode, b.Stream)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if r.URL.Path == "/v1/chat/completions" {
		if b.Stream {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = io.WriteString(w, "data: {\"id\":\"chat-joint\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"synthetic-text\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"synthetic\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"chat-joint\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"synthetic-text\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}\n\ndata: [DONE]\n\n")
			return
		}
		_, _ = io.WriteString(w, `{"id":"chat-joint","object":"chat.completion","model":"synthetic-text","choices":[{"index":0,"message":{"role":"assistant","content":"synthetic"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
		return
	}
	if r.URL.Path != "/v1/responses" {
		f.t.Error("unexpected joint wire request")
		w.WriteHeader(400)
		return
	}
	response := `{"id":"resp-joint","object":"response","status":"completed","model":"synthetic-text","output":[{"id":"msg-joint","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"synthetic","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}`
	if b.Stream {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"sequence_number\":0,\"response\":"+response+"}\n\n")
		return
	}
	_, _ = fmt.Fprint(w, response)
}
