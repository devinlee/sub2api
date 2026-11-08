//go:build unit && meton_managed && financial_http_integration

package routes

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	dbent "github.com/Wei-Shaw/sub2api/ent"
	_ "github.com/Wei-Shaw/sub2api/ent/runtime"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/lib/pq"
)

type financialWeb struct {
	db                     *sql.DB
	settings               *service.SettingService
	creator                int64
	id, token, url, config string
	client                 *http.Client
}
type financialReply struct {
	code  int
	body  []byte
	err   error
	cache string
}

/** 真实管理仓储、真实数据库和 HTTP，仅使用本轮隔离库中的专用测试身份。 */
func financialWebNew(t *testing.T, epoch int64, oldID string, parallel, timeout int) *financialWeb {
	t.Helper()
	if os.Getenv("METON_FINANCIAL_HTTP_TEST") != "isolated-v1" {
		t.Fatal("必须显式使用无外网临时来源库")
	}
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": strconv.FormatInt(epoch, 10), "FUNDS_MODE": "s2-source-v1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24)} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	v := &financialWeb{}
	var err error
	v.db, err = sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user=postgres")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = v.db.Close() })
	if err = v.db.QueryRow("SELECT id FROM users WHERE email='s2-financial-operator@example.invalid'").Scan(&v.creator); err != nil {
		t.Fatal(err)
	}
	v.settings = service.NewSettingService(nil, nil)
	v.settings.SetScopedAdminKeyRepository(repository.NewScopedAdminKeyRepository(v.db))
	key, item, err := v.settings.CreateScopedAdminKey(t.Context(), service.ScopedAdminKeyInput{Name: "financial-reader", Enabled: true, Policy: adminaccess.Policy{GlobalPermissions: []string{metonmodel.FinancialPermission}}}, v.creator)
	if err != nil {
		t.Fatal(err)
	}
	v.token, v.id = key, item.ID
	t.Setenv("METON_MANAGED_FINANCIAL_KEY_ID", v.id)
	dir := t.TempDir()
	cfg := map[string]any{"format_version": 1, "environment": "s2-isolated", "source": "s2-managed", "epoch": epoch, "parallel": parallel, "timeout_ms": timeout, "dsn_file": "read.dsn"}
	if oldID != "" {
		history := service.FinancialKeyHistory{FormatVersion: 1, Environment: "s2-isolated", Source: "s2-managed", Generations: []service.FinancialKeyGeneration{{Epoch: 1, KeyID: oldID}, {Epoch: epoch, KeyID: v.id}}}
		raw, _ := json.Marshal(history)
		sum := sha256.Sum256(raw)
		if err = os.WriteFile(filepath.Join(dir, "history.json"), raw, 0600); err != nil {
			t.Fatal(err)
		}
		cfg["recovery_keys_file"], cfg["recovery_keys_sha256"] = "history.json", hex.EncodeToString(sum[:])
	}
	if err = os.WriteFile(filepath.Join(dir, "read.dsn"), []byte("host=127.0.0.1 dbname=s2_grants sslmode=disable user=s2_financial_http"), 0600); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(cfg)
	v.config = filepath.Join(dir, "financial.json")
	if err = os.WriteFile(v.config, raw, 0600); err != nil {
		t.Fatal(err)
	}
	control, closePools, err := metonentry.OpenFinancialControl(v.config)
	if err != nil {
		t.Fatal("只读来源装配失败", err)
	}
	t.Cleanup(closePools)
	users := service.NewUserService(repository.NewUserRepository(dbent.NewClient(dbent.Driver(entsql.OpenDB(dialect.Postgres, v.db))), v.db), nil, nil, nil)
	h := admin.NewUserHandler(nil, nil, nil, nil, nil, users, v.settings)
	h.SetMetonFinancialControl(control)
	gin.SetMode(gin.TestMode)
	r := gin.New()
	group := r.Group("/api/v1/admin", gin.HandlerFunc(middleware.NewAdminAuthMiddleware(nil, users, v.settings, nil)))
	registerUserManagementRoutes(group, &handler.Handlers{Admin: &handler.AdminHandlers{User: h}})
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	v.url, v.client = srv.URL, srv.Client()
	v.client.Timeout = 8 * time.Second
	v.client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return v
}

func (v *financialWeb) call(ctx context.Context, token, suffix, body string, headers map[string][]string) financialReply {
	req, err := http.NewRequestWithContext(ctx, "GET", v.url+"/api/v1/admin"+metonmodel.FinancialRoute+suffix, strings.NewReader(body))
	if err != nil {
		return financialReply{err: err}
	}
	if token != "" {
		req.Header.Set("X-Api-Key", token)
	}
	for k, values := range headers {
		req.Header[k] = values
	}
	res, err := v.client.Do(req)
	if err != nil {
		return financialReply{err: err}
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 65537))
	return financialReply{res.StatusCode, raw, err, res.Header.Get("Cache-Control")}
}
func (v *financialWeb) expect(t *testing.T, token string, code int) *metonmodel.FinancialObservation {
	t.Helper()
	r := v.call(t.Context(), token, "", "", nil)
	if r.err != nil || r.code != code {
		t.Fatalf("观察 HTTP 预期 %d 实际 %d: %v %s", code, r.code, r.err, r.body)
	}
	if code != 200 {
		if bytes.Contains(r.body, []byte("held")) {
			t.Fatal("拒绝仍泄漏样本")
		}
		return nil
	}
	var envelope struct {
		Code int             `json:"code"`
		Data json.RawMessage `json:"data"`
	}
	if json.Unmarshal(r.body, &envelope) != nil || envelope.Code != 0 || r.cache != "no-store" {
		t.Fatal("观察外壳或缓存约束不符")
	}
	scope := metonmodel.FinancialScope{Environment: "s2-isolated", Source: "s2-managed"}
	scope.Epoch, _ = strconv.ParseInt(os.Getenv("METON_MANAGED_EPOCH"), 10, 64)
	sample, err := metonmodel.ReadFinancialObservation(envelope.Data, scope, time.Now())
	if err != nil {
		t.Fatal("返回非当前汇总", err)
	}
	for _, field := range []string{"user_id", "source_marker", "request_id", "api_key", "key_hash"} {
		if bytes.Contains(envelope.Data, []byte(`"`+field+`"`)) {
			t.Fatal("汇总夹带明细")
		}
	}
	return sample
}
func (v *financialWeb) exec(t *testing.T, q string, args ...any) {
	t.Helper()
	if _, err := v.db.Exec(q, args...); err != nil {
		t.Fatal(err)
	}
}
func (v *financialWeb) lock(t *testing.T) *sql.Tx {
	t.Helper()
	tx, err := v.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback() })
	if _, err = tx.Exec("LOCK TABLE meton_ledger.lots IN ACCESS EXCLUSIVE MODE"); err != nil {
		t.Fatal(err)
	}
	return tx
}
func (v *financialWeb) wait(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		var ready bool
		if err := v.db.QueryRow("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE usename='s2_financial_http' AND wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid))>0)").Scan(&ready); err != nil {
			t.Fatal(err)
		}
		if ready {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("未观察到实际只读 SQL 等锁")
}

func TestFinancialHTTPAuthorizationPostgres(t *testing.T) {
	v := financialWebNew(t, 1, "", 2, 4500)
	sample := v.expect(t, v.token, 200)
	if sample.Accounts < 2 || len(sample.Units) == 0 {
		t.Fatal("来源样本未读回")
	}
	for i := 0; i < 8; i++ {
		again := v.expect(t, v.token, 200)
		if again.Accounts != sample.Accounts || again.Units[0].Held != sample.Units[0].Held {
			t.Fatal("重复读取改变原汇总")
		}
	}
	v.expect(t, "", 401)
	for _, permission := range []string{metonmodel.FinancialPermission, "meton.corrections.read", "meton.managed.read"} {
		key, _, err := v.settings.CreateScopedAdminKey(t.Context(), service.ScopedAdminKeyInput{Name: "foreign-purpose", Enabled: true, Policy: adminaccess.Policy{GlobalPermissions: []string{permission}}}, v.creator)
		if err != nil {
			t.Fatal(err)
		}
		v.expect(t, key, 403)
	}
	for _, probe := range []struct {
		suffix, body string
		headers      map[string][]string
	}{
		{suffix: "?epoch=1"}, {suffix: "?"}, {body: "{}"}, {headers: map[string][]string{"Cookie": {"session=x"}}},
		{headers: map[string][]string{"Authorization": {"Bearer x"}}}, {headers: map[string][]string{"X-Api-Key": {v.token, v.token}}},
	} {
		r := v.call(t.Context(), v.token, probe.suffix, probe.body, probe.headers)
		if r.err != nil || r.code != 400 {
			t.Fatal("模糊请求被接受", r.code, r.err)
		}
	}
	v.exec(t, "UPDATE scoped_admin_api_keys SET enabled=false WHERE id=$1", v.id)
	v.expect(t, v.token, 401)
}

/** SQL 在原快照中等锁时轮换，最终交付必须使用新权限事实。 */
func TestFinancialHTTPRevocationRacePostgres(t *testing.T) {
	v := financialWebNew(t, 1, "", 1, 4500)
	lock := v.lock(t)
	done := make(chan financialReply, 1)
	old := v.token
	go func() { done <- v.call(t.Context(), old, "", "", nil) }()
	v.wait(t)
	fresh, item, err := v.settings.RotateScopedAdminKey(t.Context(), v.id)
	if err != nil || item.ID != v.id {
		t.Fatal(err)
	}
	if err = lock.Commit(); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil || r.code != 503 || bytes.Contains(r.body, []byte("held")) {
		t.Fatal("迟到观察使用旧权限", r.code, r.err)
	}
	v.expect(t, old, 401)
	v.expect(t, fresh, 200)
}

/** 读取期间只关闭来源，HTTP 复验身份仍可通过，最后的数据库栅栏必须拒绝。 */
func TestFinancialHTTPFenceRacePostgres(t *testing.T) {
	v := financialWebNew(t, 1, "", 1, 4500)
	lock := v.lock(t)
	done := make(chan financialReply, 1)
	go func() { done <- v.call(t.Context(), v.token, "", "", nil) }()
	v.wait(t)
	v.exec(t, "UPDATE meton_managed_fence SET enabled=false")
	defer v.exec(t, "UPDATE meton_managed_fence SET enabled=true")
	if err := lock.Commit(); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil || r.code != 503 || bytes.Contains(r.body, []byte("held")) {
		t.Fatal("停供后交付旧快照", r.code, r.err)
	}
	v.exec(t, "UPDATE meton_managed_fence SET enabled=true")
	v.expect(t, v.token, 200)
}

func TestFinancialHTTPRecoveryPostgres(t *testing.T) {
	old := financialWebNew(t, 1, "", 1, 4500)
	first := old.expect(t, old.token, 200)
	old.exec(t, "UPDATE meton_managed_fence SET epoch=2")
	defer old.exec(t, "UPDATE meton_managed_fence SET epoch=1")
	old.expect(t, old.token, 503)
	fresh := financialWebNew(t, 2, old.id, 1, 4500)
	observed := fresh.expect(t, fresh.token, 200)
	if observed.Accounts != first.Accounts || observed.HistoricalAccounts != observed.Accounts || observed.Units[0].Held != first.Units[0].Held {
		t.Fatal("恢复代次漏掉旧事项")
	}
	fresh.expect(t, old.token, 403)
	raw, err := os.ReadFile(fresh.config)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	_ = json.Unmarshal(raw, &cfg)
	delete(cfg, "recovery_keys_file")
	delete(cfg, "recovery_keys_sha256")
	fresh.reject(t, cfg)
	_ = json.Unmarshal(raw, &cfg)
	cfg["recovery_keys_sha256"] = strings.Repeat("0", 64)
	fresh.reject(t, cfg)
	t.Setenv("METON_MANAGED_RESULT_APPLY_KEY_ID", old.id)
	fresh.expect(t, fresh.token, 503)
	c, closePools, e := metonentry.OpenFinancialControl(fresh.config)
	closePools()
	if e == nil || c != nil {
		t.Fatal("退役 ID 被另一个用途复活")
	}
	t.Setenv("METON_MANAGED_RESULT_APPLY_KEY_ID", "")
	material := service.FinancialKeyHistory{FormatVersion: 1, Environment: "s2-isolated", Source: "s2-managed", Generations: []service.FinancialKeyGeneration{{Epoch: 1, KeyID: old.id}, {Epoch: 2, KeyID: old.id}}}
	h, _ := json.Marshal(material)
	sum := sha256.Sum256(h)
	_ = os.WriteFile(filepath.Join(filepath.Dir(fresh.config), "reused.json"), h, 0600)
	_ = json.Unmarshal(raw, &cfg)
	cfg["recovery_keys_file"], cfg["recovery_keys_sha256"] = "reused.json", hex.EncodeToString(sum[:])
	t.Setenv("METON_MANAGED_FINANCIAL_KEY_ID", old.id)
	fresh.reject(t, cfg)
}

func (v *financialWeb) reject(t *testing.T, cfg map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(cfg)
	p := filepath.Join(filepath.Dir(v.config), "rejected.json")
	if err := os.WriteFile(p, raw, 0600); err != nil {
		t.Fatal(err)
	}
	c, closePools, err := metonentry.OpenFinancialControl(p)
	closePools()
	closePools()
	if err == nil || c != nil {
		t.Fatal("错误配置放行")
	}
}
func TestFinancialHTTPConfigurationPostgres(t *testing.T) {
	v := financialWebNew(t, 1, "", 1, 4500)
	raw, _ := os.ReadFile(v.config)
	for key, value := range map[string]any{"timeout_ms": 5001, "parallel": 5, "epoch": 2, "source": "other", "unknown": true, "dsn_file": "absent.dsn"} {
		var cfg map[string]any
		_ = json.Unmarshal(raw, &cfg)
		cfg[key] = value
		v.reject(t, cfg)
	}
	for _, role := range []string{"postgres", "s2_financial_reader"} {
		p := filepath.Join(filepath.Dir(v.config), "wrong.dsn")
		if err := os.WriteFile(p, []byte("host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role), 0600); err != nil {
			t.Fatal(err)
		}
		var cfg map[string]any
		_ = json.Unmarshal(raw, &cfg)
		cfg["dsn_file"] = "wrong.dsn"
		v.reject(t, cfg)
	}
	v.exec(t, "GRANT SELECT ON meton_ledger.lots TO s2_financial_http")
	var cfg map[string]any
	_ = json.Unmarshal(raw, &cfg)
	v.reject(t, cfg)
	v.exec(t, "REVOKE SELECT ON meton_ledger.lots FROM s2_financial_http")
	t.Setenv("METON_MANAGED_KEYS_ISSUE_KEY_ID", v.id)
	v.expect(t, v.token, 503)
	v.reject(t, cfg)
}

func TestFinancialHTTPBudgetPostgres(t *testing.T) {
	v := financialWebNew(t, 1, "", 1, 4500)
	lock := v.lock(t)
	done := make(chan financialReply, 1)
	ctx, cancel := context.WithCancel(t.Context())
	go func() { done <- v.call(ctx, v.token, "", "", nil) }()
	v.wait(t)
	start := time.Now()
	v.expect(t, v.token, 503)
	if time.Since(start) > time.Second {
		t.Fatal("满额请求仍排队")
	}
	cancel()
	r := <-done
	if r.err == nil {
		t.Fatal("取消请求没有结束")
	}
	if err := lock.Commit(); err != nil {
		t.Fatal(err)
	}
	// 客户端取消不能证明服务端已归还；等实际查询退出后再验证入口可用。
	deadline := time.Now().Add(time.Second)
	for {
		r = v.call(t.Context(), v.token, "", "", nil)
		if r.err == nil && r.code == 200 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("实际查询取消后未归还名额")
		}
		time.Sleep(10 * time.Millisecond)
	}
	short := financialWebNew(t, 1, "", 1, 600)
	locked := short.lock(t)
	started := time.Now()
	go func() { done <- short.call(t.Context(), short.token, "", "", nil) }()
	short.wait(t)
	r = <-done
	if r.err != nil || r.code != 503 || time.Since(started) > 2*time.Second || bytes.Contains(r.body, []byte("held")) {
		t.Fatal("查询超时误报样本", r.code, r.err)
	}
	if err := locked.Commit(); err != nil {
		t.Fatal(err)
	}
	short.expect(t, short.token, 200)
}

/** 即使持有专用数据库连接，缺原 Key 证明、当前版本或只读事务仍不能读取汇总。 */
func TestFinancialHTTPDatabaseProofPostgres(t *testing.T) {
	v := financialWebNew(t, 1, "", 1, 4500)
	var revision time.Time
	if err := v.db.QueryRow("SELECT updated_at FROM scoped_admin_api_keys WHERE id=$1", v.id).Scan(&revision); err != nil {
		t.Fatal(err)
	}
	scope := metonmodel.FinancialScope{Environment: "s2-isolated", Source: "s2-managed", Epoch: 1}
	a, ok := metonmodel.BindFinancialAccess(v.token, v.id, v.creator, revision, time.Now().Add(4*time.Second), scope)
	if !ok {
		t.Fatal("测试身份未能绑定")
	}
	values := []any{scope.Environment, scope.Source, scope.Epoch, a.KeyID, a.CreatorID, a.Revision, a.Until.UnixMilli(), a.Witness}
	read := func(role string, readonly bool, args []any) error {
		db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role)
		if err != nil {
			return err
		}
		defer db.Close()
		tx, err := db.BeginTx(t.Context(), &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: readonly})
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if _, err = tx.Exec("SET LOCAL statement_timeout='3s'"); err != nil {
			return err
		}
		var raw []byte
		return tx.QueryRow("SELECT meton_ledger.http_read_financial_observation($1,$2,$3,$4,$5,$6,$7,$8)", args...).Scan(&raw)
	}
	denied := func(err error) {
		t.Helper()
		var dbErr *pq.Error
		if !errors.As(err, &dbErr) || dbErr.Code != "42501" {
			t.Fatal("数据库未拒绝伪造读取权限", err)
		}
	}
	if err := read("s2_financial_http", true, values); err != nil {
		t.Fatal("有效证明被拒", err)
	}
	for index, value := range map[int]any{0: "other", 1: "foreign", 2: int64(2), 3: strings.Repeat("f", 24), 4: v.creator + 1, 5: revision.Add(time.Second), 6: time.Now().Add(time.Hour).UnixMilli(), 7: strings.Repeat("0", 64)} {
		changed := append([]any(nil), values...)
		changed[index] = value
		denied(read("s2_financial_http", true, changed))
	}
	denied(read("s2_financial_http", false, values))
	denied(read("postgres", true, values))
	denied(read("s2_financial_reader", true, values))
}
