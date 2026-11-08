//go:build meton_managed && shortfall_control_integration && unit

package routes

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
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
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

type shortfallCase struct {
	Creation  uuid.UUID
	Admission metonmodel.Admission
	Selection metonmodel.ShortfallSelection
	KeyID     int64
}
type shortfallControlInput struct{ Primary, Foreign, Insufficient shortfallCase }

/** 只建立本轮三份专用数据库配置，原服务与供应模型均不参与。 */
func shortfallControlSetup(t *testing.T) (shortfallControlInput, string, map[string]any, *sql.DB) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	for name, value := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "SHORTFALL_APPLY_KEY_ID": strings.Repeat("d", 24), "SHORTFALL_READ_KEY_ID": strings.Repeat("e", 24)} {
		t.Setenv("METON_MANAGED_"+name, value)
	}
	var input shortfallControlInput
	raw, err := os.ReadFile(os.Getenv("METON_SHORTFALL_CONTROL_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &input) != nil {
		t.Fatal("缺少隔离输入", err)
	}
	dir := t.TempDir()
	for name, role := range map[string]string{"original": "s2_shortfall_original", "read": "s2_shortfall_read", "apply": "s2_shortfall_execute"} {
		if err = os.WriteFile(filepath.Join(dir, name+".dsn"), []byte("host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role), 0600); err != nil {
			t.Fatal(err)
		}
	}
	cfg := map[string]any{"format_version": 1, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1, "original_dsn_file": "original.dsn", "read_dsn_file": "read.dsn", "apply_dsn_file": "apply.dsn", "parallel": 2, "timeout_ms": 2000}
	raw, _ = json.Marshal(cfg)
	path := filepath.Join(dir, "shortfall.json")
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	// 管理连接仅供断言和权限故障注入；真实控制获得的仍是三个受限角色。
	db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user=postgres")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return input, path, cfg, db
}

/** 真实 HTTP 回包丢失后只读查回；实际来源 SQL 证明权限、账号和资金事件不混用。 */
func TestShortfallControlHTTPPostgres(t *testing.T) {
	input, config, _, db := shortfallControlSetup(t)
	control, closeControl, err := metonentry.OpenShortfallControl(config)
	if err != nil {
		t.Fatal("受限配置未启用", err)
	}
	defer closeControl()
	user := admin.NewUserHandler(nil, nil, nil, nil, nil, nil, nil)
	user.SetMetonShortfallControl(control)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		id := ""
		permissions := []string{}
		switch c.GetHeader("Test-Principal") {
		case "apply":
			id = strings.Repeat("d", 24)
			permissions = []string{"meton.shortfalls.apply"}
		case "read":
			id = strings.Repeat("e", 24)
			permissions = []string{"meton.shortfalls.read"}
		case "wrong-key":
			id = strings.Repeat("f", 24)
			permissions = []string{"meton.shortfalls.apply", "meton.shortfalls.read"}
		case "wrong-policy":
			id = strings.Repeat("d", 24)
			permissions = []string{"meton.results.apply"}
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
			// 先确认真实处理成功，再截断实际 TCP 回包；EOF 本身不是“未扣款”。
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, r)
			if rec.Code != 200 {
				t.Error("断回包前实际执行未成功", rec.Code, rec.Body.String())
			}
			conn, _, e := w.(http.Hijacker).Hijack()
			if e != nil {
				t.Error(e)
				return
			}
			_ = conn.Close()
			return
		}
		router.ServeHTTP(w, r)
	}))
	defer server.Close()
	request := func(v shortfallCase) metonmodel.ShortfallRequest {
		return metonmodel.ShortfallRequest{Version: 1, Epoch: 1, UntilMS: time.Now().Add(20 * time.Second).UnixMilli(), Admission: v.Admission, ShortfallSelection: v.Selection}
	}
	pathFor := func(v shortfallCase, action string) string {
		return "/api/v1/admin/meton/managed-accounts/" + v.Creation.String() + "/model-calls/" + v.Admission.Origin.Caller + "/" + v.Admission.Origin.OperationID + "/shortfall/" + action
	}
	call := func(v shortfallCase, action, principal, path string, raw []byte, headers map[string]string) (int, []byte, error) {
		if path == "" {
			path = pathFor(v, action)
		}
		if raw == nil {
			raw, _ = json.Marshal(request(v))
		}
		r, e := http.NewRequest("POST", server.URL+path, bytes.NewReader(raw))
		if e != nil {
			t.Fatal(e)
		}
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Test-Principal", principal)
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		response, e := server.Client().Do(r)
		if e != nil {
			return 0, nil, e
		}
		defer response.Body.Close()
		body, e := io.ReadAll(response.Body)
		if response.Header.Get("Cache-Control") != "no-store" {
			t.Error("资金回执允许缓存")
		}
		return response.StatusCode, body, e
	}
	expect := func(v shortfallCase, action, principal, path string, raw []byte, headers map[string]string, want int) []byte {
		t.Helper()
		code, body, e := call(v, action, principal, path, raw, headers)
		if e != nil || code != want {
			t.Fatalf("%s %s: %d want %d: %s %v", action, principal, code, want, body, e)
		}
		return body
	}
	decode := func(v shortfallCase, body []byte) *metonmodel.ShortfallReceipt {
		t.Helper()
		var envelope struct {
			Data json.RawMessage `json:"data"`
		}
		if json.Unmarshal(body, &envelope) != nil {
			t.Fatal("回执不是 JSON")
		}
		r, e := metonmodel.ReadShortfallReceipt(envelope.Data)
		if e != nil || r.Origin != v.Admission.Origin || r.ShortfallSelection != v.Selection {
			t.Fatal("原处置回执错配", e)
		}
		return r
	}
	state := func(v shortfallCase, commands, fees int, balance, held string) {
		t.Helper()
		var c, f, active int
		var b, h string
		e := db.QueryRow(`SELECT (SELECT count(*) FROM meton_ledger.text_shortfall_resolutions WHERE request_id=$1),(SELECT count(*) FROM meton_ledger.text_fee_reports WHERE request_id=$1),(SELECT count(*) FROM api_keys WHERE id=$2 AND status='active'),sum(l.remaining)::text,sum(l.held)::text FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=$3`, v.Admission.Origin.SourceRequestID, v.KeyID, v.Admission.Origin.SourceMarker).Scan(&c, &f, &active, &b, &h)
		if e != nil || c != commands || f != fees || active != 0 || b != balance || h != held {
			t.Fatal("资金或旧凭据状态不符", e, c, f, active, b, h)
		}
	}
	a := input.Primary
	for _, p := range []string{"", "read", "wrong-key", "wrong-policy"} {
		expect(a, "apply", p, "", nil, nil, 403)
	}
	expect(a, "resolution", "apply", "", nil, nil, 403)
	raw, _ := json.Marshal(request(a))
	for _, suffix := range []string{`,"amount":"5.00000000"}`, `,"epoch":1}`} {
		expect(a, "apply", "apply", "", append(append([]byte{}, raw[:len(raw)-1]...), []byte(suffix)...), nil, 400)
	}
	expect(a, "apply", "apply", "", bytes.Repeat([]byte(" "), 8193), nil, 400)
	expect(a, "apply", "apply", pathFor(a, "apply")+"?", nil, nil, 400)
	expect(a, "apply", "apply", "", nil, map[string]string{"Cookie": "session=untrusted"}, 400)
	expect(a, "apply", "apply", "", nil, map[string]string{"Content-Encoding": "gzip"}, 400)
	expect(a, "apply", "apply", pathFor(input.Foreign, "apply"), nil, nil, 503)
	wrongCaller := a
	wrongCaller.Admission.Origin.Caller = "meton.oc07.v1"
	expect(wrongCaller, "apply", "apply", "", nil, nil, 503)
	for _, mutate := range []func(*metonmodel.ShortfallRequest){
		func(q *metonmodel.ShortfallRequest) { q.Admission.Origin.User = uuid.NewString() },
		func(q *metonmodel.ShortfallRequest) { q.Admission.Origin.SourceMarker = uuid.NewString() },
		func(q *metonmodel.ShortfallRequest) { q.Admission.Origin.SourceRequestID = uuid.NewString() },
		func(q *metonmodel.ShortfallRequest) { q.UntilMS = time.Now().Add(-time.Second).UnixMilli() },
		func(q *metonmodel.ShortfallRequest) { q.UntilMS = time.Now().Add(time.Minute).UnixMilli() },
	} {
		q := request(a)
		mutate(&q)
		raw, _ := json.Marshal(q)
		expect(a, "apply", "apply", "", raw, nil, 503)
	}
	// 来源查无返回未确认，既不产生无效果终态，也不补一次写入。
	expect(a, "resolution", "read", "", nil, nil, 503)
	state(a, 0, 1, "2.00000000", "0.00000000")
	state(input.Foreign, 0, 1, "2.00000000", "2.00000000")
	before := applyRequests.Load()
	if _, _, e := call(a, "apply", "apply", "", nil, map[string]string{"Test-Drop-Reply": "true"}); e == nil {
		t.Fatal("没有制造实际回包丢失")
	}
	receipt := decode(a, expect(a, "resolution", "read", "", nil, nil, 200))
	if receipt.State != "covered" || receipt.Coverage == nil || applyRequests.Load() != before+1 {
		t.Fatal("丢回包后不是只查原号")
	}
	state(a, 1, 2, "0.00000000", "0.00000000")
	if !reflect.DeepEqual(receipt, decode(a, expect(a, "apply", "apply", "", nil, nil, 200))) {
		t.Fatal("重复执行改写回执")
	}
	for _, mutate := range []func(*metonmodel.ShortfallRequest){
		func(q *metonmodel.ShortfallRequest) { q.AttemptID = uuid.NewString() },
		func(q *metonmodel.ShortfallRequest) { q.BasisEvent = uuid.NewString() },
		func(q *metonmodel.ShortfallRequest) { q.ApprovalDigest = strings.Repeat("b", 64) },
	} {
		q := request(a)
		mutate(&q)
		raw, _ := json.Marshal(q)
		expect(a, "resolution", "read", "", raw, nil, 503)
		expect(a, "apply", "apply", "", raw, nil, 503)
	}
	b := input.Insufficient
	noFunds := decode(b, expect(b, "apply", "apply", "", nil, nil, 200))
	if noFunds.State != "funds_unavailable" || noFunds.Coverage != nil {
		t.Fatal("额度不足变成成功扣款")
	}
	if !reflect.DeepEqual(noFunds, decode(b, expect(b, "resolution", "read", "", nil, nil, 200))) || !reflect.DeepEqual(noFunds, decode(b, expect(b, "apply", "apply", "", nil, nil, 200))) {
		t.Fatal("无效果回执不能稳定复用")
	}
	state(b, 1, 1, "2.00000000", "2.00000000")
	mutations := []func(*metonmodel.ShortfallReceipt){
		func(r *metonmodel.ShortfallReceipt) { r.Version = 2 },
		func(r *metonmodel.ShortfallReceipt) { r.Original.Uncovered = "0.00000000" },
		func(r *metonmodel.ShortfallReceipt) { r.Original.Reference.Origin.User = uuid.NewString() },
		func(r *metonmodel.ShortfallReceipt) { r.Original.Reference.Item.EventID = uuid.NewString() },
		func(r *metonmodel.ShortfallReceipt) { r.Coverage = nil },
		func(r *metonmodel.ShortfallReceipt) { r.Coverage.Funded = "4.00000000" },
		func(r *metonmodel.ShortfallReceipt) { r.Coverage.Reference.Item.Amount = "6.00000000" },
		func(r *metonmodel.ShortfallReceipt) { r.Coverage.Reference.Item.Revision = 1 },
		func(r *metonmodel.ShortfallReceipt) { r.Coverage.Reference.Item.PreviousEventID = nil },
		func(r *metonmodel.ShortfallReceipt) { r.Coverage.Reference.Item.PriceVersion = "changed" },
		func(r *metonmodel.ShortfallReceipt) { r.Coverage.Reference.Origin.Account = uuid.NewString() },
		func(r *metonmodel.ShortfallReceipt) { r.State = "funds_unavailable" },
	}
	baseline, _ := json.Marshal(receipt)
	for i, change := range mutations {
		var modified metonmodel.ShortfallReceipt
		_ = json.Unmarshal(baseline, &modified)
		change(&modified)
		raw, _ := json.Marshal(modified)
		if _, e := metonmodel.ReadShortfallReceipt(raw); e == nil {
			t.Fatal("篡改的覆盖回执被接受", i)
		}
	}
	user.SetMetonShortfallControl(nil)
	expect(a, "resolution", "read", "", nil, nil, 503)
	user.SetMetonShortfallControl(control)
	t.Setenv("METON_MANAGED_EPOCH", "2")
	expect(a, "resolution", "read", "", nil, nil, 503)
	t.Setenv("METON_MANAGED_EPOCH", "1")
	state(a, 1, 2, "0.00000000", "0.00000000")
	state(input.Foreign, 0, 1, "2.00000000", "2.00000000")
	wire, _ := json.Marshal(map[string]any{"covered": receipt, "insufficient": noFunds, "fee_count": 2, "cover_count": 1, "old_key_active": 0, "lost_reply_query_only": true, "repeat_apply_same_event": true, "query_missing_no_write": true, "foreign_account_unchanged": true, "response_mutations_rejected": len(mutations)})
	if e := os.WriteFile(os.Getenv("METON_SHORTFALL_CONTROL_EXPORT"), wire, 0600); e != nil {
		t.Fatal(e)
	}
}

/** 三池须同库且只具备各自函数权限；配置与权限错误不能取得运行对象。 */
func TestShortfallControlConfigurationPostgres(t *testing.T) {
	_, path, cfg, db := shortfallControlSetup(t)
	if v, close, err := metonentry.OpenShortfallControl(""); err != nil || v != nil {
		t.Fatal("缺配置未关闭")
	} else {
		close()
		close()
	}
	valid := func() {
		t.Helper()
		v, close, err := metonentry.OpenShortfallControl(path)
		if err != nil || v == nil {
			t.Fatal("合法配置未通过", err)
		}
		close()
		close()
	}
	invalid := func() {
		t.Helper()
		v, close, err := metonentry.OpenShortfallControl(path)
		close()
		if err == nil || v != nil {
			t.Fatal("错误配置或越权角色被接受")
		}
	}
	write := func(v any) {
		t.Helper()
		raw, _ := json.Marshal(v)
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	valid()
	for _, change := range []map[string]any{{"format_version": 2}, {"epoch": 2}, {"source": "other"}, {"parallel": 0}, {"parallel": 17}, {"timeout_ms": 30001}, {"read_dsn_file": "apply.dsn"}, {"original_dsn_file": "read.dsn"}, {"apply_dsn_file": "missing.dsn"}, {"extra": true}} {
		copy := map[string]any{}
		for k, v := range cfg {
			copy[k] = v
		}
		for k, v := range change {
			copy[k] = v
		}
		write(copy)
		invalid()
	}
	write(cfg)
	raw, _ := json.Marshal(cfg)
	raw = append(append([]byte{}, raw[:len(raw)-1]...), []byte(`,"epoch":1}`)...)
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	invalid()
	write(cfg)
	for _, name := range []string{"SHORTFALL_READ", "RESULT_APPLY", "CREATE"} {
		t.Run(name, func(t *testing.T) { t.Setenv("METON_MANAGED_"+name+"_KEY_ID", strings.Repeat("d", 24)); invalid() })
	}
	exec := func(q string) {
		t.Helper()
		if _, err := db.Exec(q); err != nil {
			t.Fatal("隔离权限注入失败", err)
		}
	}
	for _, grant := range []struct{ add, remove string }{
		{"GRANT SELECT ON public.users TO s2_shortfall_read", "REVOKE SELECT ON public.users FROM s2_shortfall_read"},
		{"GRANT UPDATE ON public.users TO s2_shortfall_execute", "REVOKE UPDATE ON public.users FROM s2_shortfall_execute"},
		{"GRANT EXECUTE ON FUNCTION " + metonentry.ShortfallApplyFunction + " TO s2_shortfall_read", "REVOKE EXECUTE ON FUNCTION " + metonentry.ShortfallApplyFunction + " FROM s2_shortfall_read"},
		{"GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO s2_shortfall_original", "REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM s2_shortfall_original"},
	} {
		exec(grant.add)
		invalid()
		exec(grant.remove)
	}
	valid()
}
