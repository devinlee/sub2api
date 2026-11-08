//go:build meton_managed && result_control_integration && unit

package routes

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"encoding/pem"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

type resultControlInput struct {
	Creation, ForeignCreation uuid.UUID
	Admission                 metonmodel.Admission
	KeyID                     int64
}
type resultControlAccounts struct{}

/** 此夹具只替代供应账户读取；原生仓储和原生发送绑定已有独立联验证据。 */
func (resultControlAccounts) GetByID(_ context.Context, id int64) (*service.Account, error) {
	if id != 23 {
		return nil, service.ErrMetonClosed
	}
	return &service.Account{ID: 23, Platform: "openai", Type: "apikey", Status: "active", Credentials: map[string]any{"api_key": "isolated-supplier-key"}}, nil
}

/** 为本方法建立独立 TLS 端点及显式四池配置，不启动原服务。 */
func resultControlSetup(t *testing.T) (resultControlInput, string, map[string]any, *atomic.Int32) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	for name, value := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "RESULT_OBSERVE_KEY_ID": strings.Repeat("a", 24), "RESULT_READ_KEY_ID": strings.Repeat("b", 24), "RESULT_APPLY_KEY_ID": strings.Repeat("c", 24)} {
		t.Setenv("METON_MANAGED_"+name, value)
	}
	var input resultControlInput
	raw, err := os.ReadFile(os.Getenv("METON_RESULT_CONTROL_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &input) != nil {
		t.Fatal("缺本轮隔离输入", err)
	}
	var gets atomic.Int32
	upstream := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/v1/responses/resp_control" || r.Header.Get("Authorization") != "Bearer isolated-supplier-key" {
			t.Error("不是原供应只读查询")
			w.WriteHeader(403)
			return
		}
		gets.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"resp_control","model":"meton-s2-text-fixture","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2,"input_tokens_details":{"cached_tokens":0}}}`)
	}))
	_ = upstream.Listener.Close()
	upstream.Listener, err = net.Listen("tcp", "127.0.0.1:8098")
	if err != nil {
		t.Fatal(err)
	}
	upstream.StartTLS()
	t.Cleanup(upstream.Close)
	dir := t.TempDir()
	path := filepath.Join(dir, "result.json")
	write := func(name string, body []byte) {
		if e := os.WriteFile(filepath.Join(dir, name), body, 0600); e != nil {
			t.Fatal(e)
		}
	}
	write("ca.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: upstream.Certificate().Raw}))
	for name, role := range map[string]string{"original": "s2_result_original", "read": "s2_result_read", "observe": "s2_resolution_observe", "apply": "s2_resolution_apply"} {
		write(name+".dsn", []byte("host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role))
	}
	cfg := map[string]any{"format_version": 1, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1, "original_dsn_file": "original.dsn", "read_dsn_file": "read.dsn", "observe_dsn_file": "observe.dsn", "apply_dsn_file": "apply.dsn", "targets": []string{upstream.URL + "/v1/responses"}, "parallel": 1, "timeout_ms": 2000, "ca_file": "ca.pem"}
	raw, _ = json.Marshal(cfg)
	write("result.json", raw)
	return input, path, cfg, &gets
}

/** 管理连接只用于隔离断言和权限故障注入，正式控制代码拿不到它。 */
func resultControlDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user=postgres")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

/** 新四路 HTTP 经正式解析、权限和原来源函数；人员／管理身份为显式夹具，不能替代最终两 Host 联验。 */
func TestResultControlHTTPPostgres(t *testing.T) {
	input, path, _, gets := resultControlSetup(t)
	db := resultControlDB(t)
	control, close, err := metonentry.OpenResultControl(path, resultControlAccounts{})
	if err != nil {
		t.Fatal("配置与权限", err)
	}
	defer close()
	user := admin.NewUserHandler(nil, nil, nil, nil, nil, nil, nil)
	user.SetMetonResultControl(control)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		var id string
		var permissions []string
		switch c.GetHeader("Test-Principal") {
		case "observe":
			id = strings.Repeat("a", 24)
			permissions = []string{"meton.results.observe"}
		case "read":
			id = strings.Repeat("b", 24)
			permissions = []string{"meton.results.read"}
		case "apply":
			id = strings.Repeat("c", 24)
			permissions = []string{"meton.results.apply"}
		case "wrong-key":
			id = strings.Repeat("d", 24)
			permissions = []string{"meton.results.observe", "meton.results.apply", "meton.results.read"}
		case "wrong-policy":
			id = strings.Repeat("a", 24)
			permissions = []string{"meton.models.inspect"}
		}
		if id != "" {
			c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), &adminaccess.Principal{KeyID: id, Policy: adminaccess.Policy{GlobalPermissions: permissions}}))
		}
		c.Next()
	})
	registerUserManagementRoutes(router.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: user}})
	var applyRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/apply") {
			applyRequests.Add(1)
		}
		if r.Header.Get("Test-Drop-Reply") == "true" {
			// 来源已实际处理后关闭连接，调用方必须以原号读取，不能把 EOF 当作没有结算。
			recorder := httptest.NewRecorder()
			router.ServeHTTP(recorder, r)
			connection, _, e := w.(http.Hijacker).Hijack()
			if e != nil {
				t.Error(e)
				return
			}
			_ = connection.Close()
			return
		}
		router.ServeHTTP(w, r)
	}))
	defer server.Close()
	selection := metonmodel.ReconciliationSelection{EvidenceID: uuid.NewString(), CaseID: uuid.NewString(), AttemptID: uuid.NewString(), ApprovalDigest: strings.Repeat("f", 64)}
	request := func() metonmodel.ReconciliationRequest {
		return metonmodel.ReconciliationRequest{Version: 1, Epoch: 1, UntilMS: time.Now().Add(20 * time.Second).UnixMilli(), Admission: input.Admission, ReconciliationSelection: selection}
	}
	pathFor := func(creation uuid.UUID, caller, action string) string {
		return "/api/v1/admin/meton/managed-accounts/" + creation.String() + "/model-calls/" + caller + "/" + input.Admission.Origin.OperationID + "/reconciliation/" + action
	}
	call := func(action, principal, pathOverride string, raw []byte, extra map[string]string) (int, []byte, error) {
		p := pathFor(input.Creation, input.Admission.Origin.Caller, action)
		if pathOverride != "" {
			p = pathOverride
		}
		if raw == nil {
			raw, _ = json.Marshal(request())
		}
		r, e := http.NewRequest("POST", server.URL+p, bytes.NewReader(raw))
		if e != nil {
			t.Fatal(e)
		}
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Test-Principal", principal)
		for k, v := range extra {
			r.Header.Set(k, v)
		}
		response, e := server.Client().Do(r)
		if e != nil {
			return 0, nil, e
		}
		defer response.Body.Close()
		body, e := io.ReadAll(response.Body)
		if response.Header.Get("Cache-Control") != "no-store" {
			t.Error("缺少不缓存声明")
		}
		return response.StatusCode, body, e
	}
	expect := func(action, principal, path string, raw []byte, headers map[string]string, status int) []byte {
		t.Helper()
		got, body, e := call(action, principal, path, raw, headers)
		if e != nil || got != status {
			t.Fatalf("%s %s: %d expected %d: %s %v", action, principal, got, status, body, e)
		}
		return body
	}
	decode := func(body []byte) *metonmodel.ReconciliationReceipt {
		t.Helper()
		var envelope struct {
			Data json.RawMessage `json:"data"`
		}
		if json.Unmarshal(body, &envelope) != nil {
			t.Fatal("响应不是 JSON")
		}
		receipt, e := metonmodel.ReadReconciliationReceipt(envelope.Data)
		if e != nil || receipt.ReconciliationSelection != selection || receipt.Origin != input.Admission.Origin {
			t.Fatal("原凭证错配", e)
		}
		return receipt
	}
	state := func(fees int, held, balance string) {
		t.Helper()
		var f, active int
		var h, b string
		o := input.Admission.Origin
		e := db.QueryRow(`SELECT (SELECT count(*) FROM meton_ledger.text_fee_reports WHERE request_id=$1),(SELECT count(*) FROM api_keys WHERE id=$2 AND status='active'),sum(l.held)::text,sum(l.remaining)::text FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=$3`, o.SourceRequestID, input.KeyID, o.SourceMarker).Scan(&f, &active, &h, &b)
		if e != nil || f != fees || active != 0 || h != held || b != balance {
			t.Fatal("控制接缝改变非目标事实", e, f, active, h, b)
		}
	}
	for _, principal := range []string{"", "wrong-key", "wrong-policy", "read", "apply"} {
		expect("observe", principal, "", nil, nil, 403)
	}
	expect("apply", "observe", "", nil, nil, 403)
	expect("resolution", "apply", "", nil, nil, 403)
	raw, _ := json.Marshal(request())
	expect("observe", "observe", "", append(append([]byte{}, raw[:len(raw)-1]...), []byte(`,"amount":"9.0"}`)...), nil, 400)
	expect("observe", "observe", "", append(append([]byte{}, raw[:len(raw)-1]...), []byte(`,"epoch":1}`)...), nil, 400)
	expect("observe", "observe", pathFor(input.Creation, input.Admission.Origin.Caller, "observe")+"?again=1", nil, nil, 400)
	expect("observe", "observe", "", nil, map[string]string{"Cookie": "untrusted=true"}, 400)
	expect("observe", "observe", pathFor(input.ForeignCreation, input.Admission.Origin.Caller, "observe"), nil, nil, 503)
	expect("observe", "observe", pathFor(input.Creation, "meton.oc07.v1", "observe"), nil, nil, 503)
	changed := request()
	changed.Admission.Origin.User = uuid.NewString()
	raw, _ = json.Marshal(changed)
	expect("observe", "observe", "", raw, nil, 503)
	changed = request()
	changed.UntilMS = time.Now().Add(-time.Second).UnixMilli()
	raw, _ = json.Marshal(changed)
	expect("observe", "observe", "", raw, nil, 503)
	changed = request()
	changed.UntilMS = time.Now().Add(time.Minute).UnixMilli()
	raw, _ = json.Marshal(changed)
	expect("observe", "observe", "", raw, nil, 503)
	expect("proof", "read", "", nil, nil, 503)
	expect("resolution", "read", "", nil, nil, 503)
	expect("apply", "apply", "", nil, nil, 503)
	if gets.Load() != 0 {
		t.Fatal("只读查询或拒绝请求访问了供应")
	}
	state(0, "3.00000000", "5.00000000")
	observed := decode(expect("observe", "observe", "", nil, nil, 200))
	if observed.State != "observed" || observed.EventID != nil || gets.Load() != 1 {
		t.Fatal("观察未独立")
	}
	state(0, "3.00000000", "5.00000000")
	if !reflect.DeepEqual(observed, decode(expect("proof", "read", "", nil, nil, 200))) {
		t.Fatal("证明查询不匹配")
	}
	if !reflect.DeepEqual(observed, decode(expect("observe", "observe", "", nil, nil, 200))) || gets.Load() != 1 {
		t.Fatal("观察重放没有复用原证明")
	}
	before := applyRequests.Load()
	if _, _, e := call("apply", "apply", "", nil, map[string]string{"Test-Drop-Reply": "true"}); e == nil {
		t.Fatal("断开回包未注入")
	}
	resolved := decode(expect("resolution", "read", "", nil, nil, 200))
	if resolved.State != "resolved" || resolved.EventID == nil || applyRequests.Load() != before+1 {
		t.Fatal("丢回包后不是只读原结算")
	}
	state(1, "0.00000000", "3.00000000")
	if !reflect.DeepEqual(resolved, decode(expect("apply", "apply", "", nil, nil, 200))) {
		t.Fatal("供应端重复请求产生新结算")
	}
	changed = request()
	changed.AttemptID = uuid.NewString()
	raw, _ = json.Marshal(changed)
	expect("resolution", "read", "", raw, nil, 503)
	expect("apply", "apply", "", raw, nil, 503)
	user.SetMetonResultControl(nil)
	expect("resolution", "read", "", nil, nil, 503)
	user.SetMetonResultControl(control)
	t.Setenv("METON_MANAGED_EPOCH", "2")
	expect("resolution", "read", "", nil, nil, 503)
	t.Setenv("METON_MANAGED_EPOCH", "1")
	state(1, "0.00000000", "3.00000000")
	if gets.Load() != 1 {
		t.Fatal("后续查询再次访问供应")
	}
	wire, _ := json.Marshal(map[string]any{"observation": observed, "resolution": resolved, "http_get_count": gets.Load(), "model_post_count": 0, "fee_count": 1, "old_key_active": 0, "lost_reply_query_only": true, "repeat_apply_same_event": true})
	if e := os.WriteFile(os.Getenv("METON_RESULT_CONTROL_EXPORT"), wire, 0600); e != nil {
		t.Fatal(e)
	}
}

/** 运行配置缺失时关闭；错归属、兼任角色和额外裸表读取不能带着恢复资金能力启动。 */
func TestResultControlConfigurationPostgres(t *testing.T) {
	_, path, cfg, gets := resultControlSetup(t)
	db := resultControlDB(t)
	if control, close, err := metonentry.OpenResultControl("", nil); err != nil || control != nil {
		t.Fatal("缺配置未关闭")
	} else {
		close()
		close()
	}
	valid := func() {
		t.Helper()
		control, close, err := metonentry.OpenResultControl(path, resultControlAccounts{})
		if err != nil || control == nil {
			t.Fatal("完整配置未通过", err)
		}
		close()
		close()
	}
	valid()
	for _, change := range []map[string]any{{"epoch": 2}, {"source": "other"}, {"parallel": 17}, {"timeout_ms": 30001}, {"read_dsn_file": "observe.dsn"}, {"targets": []string{"http://127.0.0.1:8098/v1/responses"}}, {"extra": true}} {
		copy := map[string]any{}
		for k, v := range cfg {
			copy[k] = v
		}
		for k, v := range change {
			copy[k] = v
		}
		raw, _ := json.Marshal(copy)
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
		control, close, err := metonentry.OpenResultControl(path, resultControlAccounts{})
		close()
		if err == nil || control != nil {
			t.Fatal("错误配置被接受", change)
		}
	}
	raw, _ := json.Marshal(cfg)
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("METON_MANAGED_RESULT_APPLY_KEY_ID", strings.Repeat("b", 24))
	if value, close, err := metonentry.OpenResultControl(path, resultControlAccounts{}); err == nil || value != nil {
		t.Fatal("身份可兼任")
	} else {
		close()
	}
	t.Setenv("METON_MANAGED_RESULT_APPLY_KEY_ID", strings.Repeat("c", 24))
	if _, err := db.Exec("GRANT SELECT ON public.users TO s2_result_read"); err != nil {
		t.Fatal(err)
	}
	value, close, err := metonentry.OpenResultControl(path, resultControlAccounts{})
	close()
	if err == nil || value != nil {
		t.Fatal("多余裸表权限被接受")
	}
	if _, err = db.Exec("REVOKE SELECT ON public.users FROM s2_result_read"); err != nil {
		t.Fatal(err)
	}
	valid()
	if gets.Load() != 0 {
		t.Fatal("配置检查执行了供应请求")
	}
}
