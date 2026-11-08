//go:build unit && meton_managed && correction_http_integration

package routes

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
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
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

type correctionOwner struct {
	Creation, Dispatch, Item, Basis, Gift, Purchase string
	RemoteUser, RemoteKey                           int64
	Admission                                       metonmodel.Admission
}

type correctionWeb struct {
	db       *sql.DB
	settings *service.SettingService
	repo     service.ScopedAdminKeyRepository
	creator  int64
	tokens   map[string]string
	ids      map[string]string
	config   string
	url      string
	client   *http.Client
	drop     atomic.Bool
	accounts map[string]correctionOwner
}

// 只安排一次真实密钥撤销与结果交付的先后，查询、写入和鉴权仍全部使用原库。
type correctionKeySequencer struct {
	service.ScopedAdminKeyRepository
	waitID         string
	decision       string
	db             *sql.DB
	ready, proceed chan struct{}
	next           atomic.Bool
}

func (s *correctionKeySequencer) GetScopedAdminKey(ctx context.Context, id string) (*service.ScopedAdminKey, error) {
	if id == s.waitID && s.next.Load() {
		var committed bool
		if err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT FROM meton_ledger.operations_correction_effects WHERE decision=$1)", s.decision).Scan(&committed); err != nil {
			return nil, err
		}
		if !committed || !s.next.CompareAndSwap(true, false) {
			return s.ScopedAdminKeyRepository.GetScopedAdminKey(ctx, id)
		}
		close(s.ready)
		select {
		case <-s.proceed:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return s.ScopedAdminKeyRepository.GetScopedAdminKey(ctx, id)
}

func newCorrectionWeb(t *testing.T, epoch int64, sequencer *correctionKeySequencer) *correctionWeb {
	t.Helper()
	return correctionWebFromHistory(t, epoch, sequencer, nil)
}

func correctionWebFromHistory(t *testing.T, epoch int64, sequencer *correctionKeySequencer, previous map[string]string) *correctionWeb {
	t.Helper()
	raw, err := os.ReadFile(os.Getenv("METON_CORRECTION_HTTP_FIXTURE"))
	v := &correctionWeb{tokens: map[string]string{}, ids: map[string]string{}}
	if err != nil || json.Unmarshal(raw, &v.accounts) != nil {
		t.Fatal("缺少来源样本", err)
	}
	for k, x := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "FUNDS_MODE": "s2-source-v1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24)} {
		t.Setenv("METON_MANAGED_"+k, x)
	}
	t.Setenv("METON_MANAGED_EPOCH", strconv.FormatInt(epoch, 10))
	v.db, err = sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user=postgres")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = v.db.Close() })
	if err = v.db.QueryRow("SELECT id FROM users WHERE email='s2-correction-operator@example.invalid' AND role='admin' AND status='active' AND deleted_at IS NULL").Scan(&v.creator); err != nil {
		t.Fatal("原隔离库没有可用测试管理员", err)
	}
	v.repo = repository.NewScopedAdminKeyRepository(v.db)
	v.settings = service.NewSettingService(nil, nil)
	v.settings.SetScopedAdminKeyRepository(v.repo)
	roles := map[string]string{"read": "meton.corrections.read", "approve": "meton.corrections.approve", "apply": "meton.corrections.apply"}
	for action, scope := range roles {
		key, item, e := v.settings.CreateScopedAdminKey(t.Context(), service.ScopedAdminKeyInput{Name: "correction-" + action, Enabled: true,
			Policy: adminaccess.Policy{GlobalPermissions: []string{scope}}}, v.creator)
		if e != nil {
			t.Fatal("原生受限管理身份未创建", e)
		}
		v.tokens[action], v.ids[action] = key, item.ID
		t.Setenv("METON_MANAGED_CORRECTION_"+strings.ToUpper(action)+"_KEY_ID", item.ID)
	}
	if sequencer != nil {
		sequencer.ScopedAdminKeyRepository = v.repo
		sequencer.waitID = v.ids["apply"]
		v.settings.SetScopedAdminKeyRepository(sequencer)
	}
	dir := t.TempDir()
	cfg := map[string]any{"format_version": 1, "environment": "s2-isolated", "source": "s2-managed", "epoch": epoch, "parallel": 4, "timeout_ms": 14000}
	if previous != nil {
		history := service.CorrectionKeyHistory{FormatVersion: 1, Environment: "s2-isolated", Source: "s2-managed", Generations: []service.CorrectionKeyGeneration{
			{Epoch: 1, ReadID: previous["read"], ApproveID: previous["approve"], ApplyID: previous["apply"]},
			{Epoch: epoch, ReadID: v.ids["read"], ApproveID: v.ids["approve"], ApplyID: v.ids["apply"]}}}
		material, _ := json.Marshal(history)
		sum := sha256.Sum256(material)
		cfg["recovery_keys_file"] = "external-key-history.json"
		cfg["recovery_keys_sha256"] = hex.EncodeToString(sum[:])
		if err = os.WriteFile(filepath.Join(dir, "external-key-history.json"), material, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for field, role := range map[string]string{"original": "s2_http_correction_original", "read": "s2_http_correction_read",
		"approve": "s2_http_correction_approve", "apply": "s2_http_correction_apply"} {
		name := field + ".dsn"
		if err = os.WriteFile(filepath.Join(dir, name), []byte("host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role), 0600); err != nil {
			t.Fatal(err)
		}
		cfg[field+"_dsn_file"] = name
	}
	raw, _ = json.Marshal(cfg)
	v.config = filepath.Join(dir, "correction.json")
	if err = os.WriteFile(v.config, raw, 0600); err != nil {
		t.Fatal(err)
	}
	control, closePools, err := metonentry.OpenCorrectionControl(v.config)
	if err != nil {
		t.Fatal("受限来源配置失败", err)
	}
	t.Cleanup(closePools)
	client := dbent.NewClient(dbent.Driver(entsql.OpenDB(dialect.Postgres, v.db)))
	users := service.NewUserService(repository.NewUserRepository(client, v.db), nil, nil, nil)
	user, userErr := users.GetByID(t.Context(), v.creator)
	if userErr != nil || user == nil || !user.IsActive() || !user.IsAdmin() {
		t.Fatal("原管理员用户仓储不能确认测试创建者", userErr)
	}
	if _, keyErr := v.settings.AuthenticateScopedAdminKey(t.Context(), v.tokens["read"], "127.0.0.1"); keyErr != nil {
		t.Fatal("原生管理密钥未能认证隔离读取身份", keyErr)
	}
	h := admin.NewUserHandler(nil, nil, nil, nil, nil, users, v.settings)
	h.SetMetonCorrectionControl(control)
	gin.SetMode(gin.TestMode)
	r := gin.New()
	g := r.Group("/api/v1/admin", gin.HandlerFunc(middleware.NewAdminAuthMiddleware(nil, users, v.settings, nil)))
	registerUserManagementRoutes(g, &handler.Handlers{Admin: &handler.AdminHandlers{User: h}})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if strings.HasSuffix(req.URL.Path, "/apply") && v.drop.CompareAndSwap(true, false) {
			rec := httptest.NewRecorder()
			r.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				t.Errorf("断流前未成功提交：%d %s", rec.Code, rec.Body.String())
			}
			conn, _, e := w.(http.Hijacker).Hijack()
			if e != nil {
				t.Error(e)
				return
			}
			_ = conn.Close()
			return
		}
		r.ServeHTTP(w, req)
	}))
	t.Cleanup(srv.Close)
	v.url, v.client = srv.URL, srv.Client()
	v.client.Timeout = 20 * time.Second
	v.client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return v
}

type correctionReply struct {
	code int
	body []byte
	err  error
}

func (v *correctionWeb) call(owner correctionOwner, action, key string, body []byte, extra map[string]string) correctionReply {
	path := "/api/v1/admin/meton/managed-accounts/" + owner.Creation + "/model-calls/" + owner.Admission.Origin.Caller + "/" + owner.Admission.Origin.OperationID + "/correction/" + action
	r, err := http.NewRequest("POST", v.url+path, bytes.NewReader(body))
	if err != nil {
		return correctionReply{err: err}
	}
	r.Header.Set("Content-Type", "application/json")
	if key != "" {
		r.Header.Set("x-api-key", key)
	}
	for k, x := range extra {
		r.Header.Set(k, x)
	}
	resp, err := v.client.Do(r)
	if err != nil {
		return correctionReply{err: err}
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if resp.StatusCode == 200 && resp.Header.Get("Cache-Control") != "no-store" {
		return correctionReply{err: service.ErrMetonClosed}
	}
	return correctionReply{resp.StatusCode, raw, err}
}

func (v *correctionWeb) request(o correctionOwner, k *metonmodel.CorrectionSelection, action string) metonmodel.CorrectionRequest {
	q := metonmodel.CorrectionRequest{Version: 1, Epoch: o.Admission.AcceptedEpoch, UntilMS: time.Now().Add(18 * time.Second).UnixMilli(),
		Admission: o.Admission, Item: o.Item, Basis: o.Basis, Selection: k}
	if action == "basis" {
		q.Page = &metonmodel.CorrectionPageQuery{Limit: 1}
		q.Selection = nil
	}
	if action == "approve" {
		q.Review = &metonmodel.CorrectionReview{ValidUntilMS: time.Now().Add(time.Minute).UnixMilli(),
			Sources: []metonmodel.CorrectionLine{{CreditEvent: o.Gift, Amount: "1.00000000"}}}
	}
	return q
}
func correctionSelection() *metonmodel.CorrectionSelection {
	return &metonmodel.CorrectionSelection{Decision: uuid.NewString(), CaseID: uuid.NewString(), AttemptID: uuid.NewString(), RulingVersion: 1, Generation: 1,
		ApprovalDigest: strings.ReplaceAll(uuid.NewString()+uuid.NewString(), "-", "")}
}
func (v *correctionWeb) expect(t *testing.T, o correctionOwner, action, identity string, q metonmodel.CorrectionRequest, want int) json.RawMessage {
	t.Helper()
	raw, _ := json.Marshal(q)
	r := v.call(o, action, v.tokens[identity], raw, nil)
	if r.err != nil || r.code != want {
		t.Fatalf("%s HTTP %d，预期 %d，%s %v", action, r.code, want, string(r.body), r.err)
	}
	if want != 200 {
		return nil
	}
	var envelope struct {
		Data metonmodel.CorrectionEnvelope `json:"data"`
	}
	if json.Unmarshal(r.body, &envelope) != nil || envelope.Data.Version != 1 || envelope.Data.Action != action || envelope.Data.Epoch != q.Epoch ||
		envelope.Data.Origin != q.Admission.Origin || len(envelope.Data.Data) == 0 {
		t.Fatal("响应归属与原请求不符")
	}
	return envelope.Data.Data
}
func (v *correctionWeb) effects(t *testing.T, decision string) (int, string) {
	t.Helper()
	var n int
	var journal string
	err := v.db.QueryRow("SELECT count(*),coalesce(min(journal::text),'') FROM meton_ledger.operations_correction_effects WHERE decision=$1", decision).Scan(&n, &journal)
	if err != nil {
		t.Fatal(err)
	}
	return n, journal
}

/** 从原生管理认证、正式路由一路到真实资金事务；HTTP 响应断开后只能用只读身份查回。 */
func TestCorrectionHTTPPostgres(t *testing.T) {
	v := newCorrectionWeb(t, 1, nil)
	s, foreign := v.accounts["main"], v.accounts["foreign"]
	k := correctionSelection()
	q := v.request(s, k, "basis")
	page := v.expect(t, s, "basis", "read", q, 200)
	var p struct {
		Next *metonmodel.CorrectionBasisCursor `json:"next"`
	}
	if json.Unmarshal(page, &p) != nil || p.Next == nil {
		t.Fatal("缺少原批次分页")
	}
	q.Page.Cursor = p.Next
	v.expect(t, s, "basis", "read", q, 200)
	review := v.request(s, k, "approve")
	v.expect(t, s, "approve", "read", review, 403)
	v.expect(t, s, "approve", "apply", review, 403)
	v.expect(t, s, "resolution", "read", v.request(s, k, "resolution"), 404)
	v.expect(t, s, "approve", "approve", review, 200)
	v.expect(t, s, "basis", "read", q, 503)
	exec := v.request(s, k, "apply")
	v.expect(t, s, "apply", "approve", exec, 403)
	v.expect(t, foreign, "apply", "apply", exec, 503)
	forged := exec
	forged.Review = review.Review
	v.expect(t, s, "apply", "apply", forged, 400)
	raw, _ := json.Marshal(exec)
	for _, headers := range []map[string]string{{"Cookie": "s=unsupported"}, {"Authorization": "Bearer extra"}, {"Content-Encoding": "identity"}} {
		r := v.call(s, "apply", v.tokens["apply"], raw, headers)
		if r.code != 400 {
			t.Fatal("混合凭据或编码被接受", r.code)
		}
	}
	if n, _ := v.effects(t, k.Decision); n != 0 {
		t.Fatal("未授权或替代账号造成返还")
	}
	v.drop.Store(true)
	if r := v.call(s, "apply", v.tokens["apply"], raw, nil); r.err == nil {
		t.Fatal("客户端实际收到被截断的回包")
	}
	data := v.expect(t, s, "resolution", "read", v.request(s, k, "resolution"), 200)
	var result struct {
		State   string
		Journal string
	}
	n, j := v.effects(t, k.Decision)
	if json.Unmarshal(data, &result) != nil || result.State != "applied" || n != 1 || j == "" || result.Journal != j {
		t.Fatal("断流后未找到同一笔资金流水")
	}
	if len(v.expect(t, s, "apply", "apply", exec, 200)) == 0 {
		t.Fatal("原号重放缺回执")
	}
	if n, after := v.effects(t, k.Decision); n != 1 || after != j {
		t.Fatal("重放重复返还")
	}
}
