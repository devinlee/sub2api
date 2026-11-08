//go:build unit && meton_managed && correction_http_integration

package routes

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

func (v *correctionWeb) waitForLock(t *testing.T, filter string) {
	t.Helper()
	end := time.Now().Add(6 * time.Second)
	for time.Now().Before(end) {
		var ok bool
		if err := v.db.QueryRow("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid))>0 AND " + filter + ")").Scan(&ok); err != nil {
			t.Fatal(err)
		}
		if ok {
			return
		}
		time.Sleep(15 * time.Millisecond)
	}
	t.Fatal("未观察到真实来源阻塞", filter)
}

/** 先轮换等账号锁的旧凭据；再使新请求先锁住密钥，核对撤销、资金和交付的实际顺序。 */
func TestCorrectionHTTPAuthorityRacePostgres(t *testing.T) {
	seq := &correctionKeySequencer{ready: make(chan struct{}), proceed: make(chan struct{})}
	v := newCorrectionWeb(t, 1, seq)
	s := v.accounts["main"]
	k := correctionSelection()
	v.expect(t, s, "approve", "approve", v.request(s, k, "approve"), 200)
	lock, err := v.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback()
	if _, err = lock.Exec("SELECT id FROM users WHERE id=$1 FOR UPDATE", s.RemoteUser); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(v.request(s, k, "apply"))
	done := make(chan correctionReply, 1)
	oldToken := v.tokens["apply"]
	go func() { done <- v.call(s, "apply", oldToken, raw, nil) }()
	v.waitForLock(t, "usename='s2_http_correction_apply'")
	fresh, rotated, err := v.settings.RotateScopedAdminKey(t.Context(), v.ids["apply"])
	if err != nil || rotated.ID != v.ids["apply"] {
		t.Fatal("在资金等锁期间轮换失败", err)
	}
	if err = lock.Commit(); err != nil {
		t.Fatal(err)
	}
	if r := <-done; r.err != nil || r.code != 503 {
		t.Fatal("旧 Key 越过账户锁", r.code, r.err)
	}
	if n, _ := v.effects(t, k.Decision); n != 0 {
		t.Fatal("已轮换的服务身份修改资金")
	}
	if r := v.call(s, "apply", oldToken, raw, nil); r.err != nil || r.code != 401 {
		t.Fatal("旧凭据再次入站", r.code, r.err)
	}
	v.tokens["apply"] = fresh
	// 在资金事务已持有真实管理行锁后，将它保持在提交期；原生撤销必须排在这次写入之后。
	if _, err = v.db.Exec(`CREATE FUNCTION public.correction_http_commit_fixture() RETURNS trigger LANGUAGE plpgsql AS $$
	BEGIN PERFORM pg_advisory_xact_lock(614284); RETURN NULL; END $$;
	CREATE CONSTRAINT TRIGGER correction_http_commit_fixture AFTER INSERT ON meton_ledger.operations_correction_effects
	DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.correction_http_commit_fixture()`); err != nil {
		t.Fatal(err)
	}
	defer v.db.Exec("DROP TRIGGER correction_http_commit_fixture ON meton_ledger.operations_correction_effects; DROP FUNCTION public.correction_http_commit_fixture()")
	gate, err := v.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer gate.Rollback()
	if _, err = gate.Exec("SELECT pg_advisory_xact_lock(614284)"); err != nil {
		t.Fatal(err)
	}
	seq.db, seq.decision = v.db, k.Decision
	seq.next.Store(true)
	defer close(seq.proceed)
	raw, _ = json.Marshal(v.request(s, k, "apply"))
	go func() { done <- v.call(s, "apply", fresh, raw, nil) }()
	v.waitForLock(t, "usename='s2_http_correction_apply' AND wait_event='advisory'")
	revoked := make(chan error, 1)
	go func() { revoked <- v.settings.RevokeScopedAdminKey(t.Context(), v.ids["apply"]) }()
	v.waitForLock(t, "query LIKE 'UPDATE scoped_admin_api_keys SET revoked_at%'")
	if err = gate.Commit(); err != nil {
		t.Fatal(err)
	}
	if err = <-revoked; err != nil {
		t.Fatal(err)
	}
	select {
	case <-seq.ready:
	case <-time.After(5 * time.Second):
		t.Fatal("交付没有复验原密钥")
	}
	seq.proceed <- struct{}{}
	if r := <-done; r.err != nil || r.code != 503 || strings.Contains(string(r.body), "journal") {
		t.Fatal("撤销后仍交付资金内容", r.code, r.err)
	}
	data := v.expect(t, s, "resolution", "read", v.request(s, k, "resolution"), 200)
	var receipt struct{ State, Journal string }
	n, j := v.effects(t, k.Decision)
	if json.Unmarshal(data, &receipt) != nil || n != 1 || receipt.State != "applied" || j != receipt.Journal {
		t.Fatal("撤销后未按原号找回唯一流水")
	}
}

/** 当前来源按原对象读历史，不能以新代次替旧受理获得写权。 */
func TestCorrectionHTTPRecoveryPostgres(t *testing.T) {
	old := newCorrectionWeb(t, 1, nil)
	s := old.accounts["main"]
	k := correctionSelection()
	old.expect(t, s, "approve", "approve", old.request(s, k, "approve"), 200)
	old.expect(t, s, "apply", "apply", old.request(s, k, "apply"), 200)
	n, j := old.effects(t, k.Decision)
	second := correctionSelection()
	second.CaseID = k.CaseID
	second.RulingVersion = 2
	old.expect(t, s, "approve", "approve", old.request(s, second, "approve"), 200)
	var claim []byte
	if err := old.db.QueryRow("SELECT claim FROM meton_managed_keys WHERE remote_key=$1", s.RemoteKey).Scan(&claim); err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(claim, &fields); err != nil {
		t.Fatal(err)
	}
	closure := map[string]any{"operation": uuid.NewString()}
	for _, f := range []string{"origin", "remoteUser", "sourceMarker", "session"} {
		closure[f] = fields[f]
	}
	body, _ := json.Marshal(closure)
	o := s.Admission.Origin
	if _, err := old.db.Exec("SELECT public.meton_close_original_session($1,$2,$3,$4,clock_timestamp()+interval '25 seconds')", o.Environment, o.Source, 1, string(body)); err != nil {
		t.Fatal(err)
	}
	if _, err := old.db.Exec("UPDATE meton_managed_fence SET enabled=false"); err != nil {
		t.Fatal(err)
	}
	old.expect(t, s, "apply", "apply", old.request(s, second, "apply"), 503)
	if _, err := old.db.Exec("SELECT public.meton_recover_original($1,$2,$3,1,2,$4,$5,$6,$7,$8,$9,$10)",
		o.Environment, o.User, uuid.NewString(), o.Source, o.Account, s.Creation, s.Dispatch, s.RemoteUser, o.SourceMarker, strings.Repeat("a", 64)); err != nil {
		t.Fatal(err)
	}
	if _, err := old.db.Exec("UPDATE meton_managed_fence SET epoch=2,enabled=true"); err != nil {
		t.Fatal(err)
	}
	current := correctionWebFromHistory(t, 2, nil, old.ids)
	// 恢复库中三枚原管理密钥均仍可通过原生鉴权，隔离来自新代的明确身份，而非测试预先删除了旧密钥。
	for _, a := range []struct{ action, role string }{{"resolution", "read"}, {"approve", "approve"}, {"apply", "apply"}} {
		if _, err := current.settings.AuthenticateScopedAdminKey(t.Context(), old.tokens[a.role], "127.0.0.1"); err != nil {
			t.Fatal("旧原生密钥输入并未保持可认证", err)
		}
		q := current.request(s, k, a.action)
		q.Epoch = 2
		raw, _ := json.Marshal(q)
		if r := current.call(s, a.action, old.tokens[a.role], raw, nil); r.code != 403 || r.err != nil {
			t.Fatal("新代接纳退役服务身份", a.role, r.code, r.err)
		}
	}
	originalQuery := old.request(s, k, "resolution")
	old.expect(t, s, "resolution", "read", originalQuery, 503)
	checkCorrectionHistoryRejections(t, current, old.ids)
	for _, a := range []string{"resolution", "basis"} {
		q := current.request(s, k, a)
		q.Epoch = 2
		raw := current.expect(t, s, a, "read", q, 200)
		if a == "resolution" {
			var result struct {
				Epoch   int64
				Journal string
			}
			if json.Unmarshal(raw, &result) != nil || result.Epoch != 1 || result.Journal != j || n != 1 {
				t.Fatal("历史执行被替换或重建")
			}
		}
	}
	q := current.request(s, second, "apply")
	q.Epoch = 2
	current.expect(t, s, "apply", "apply", q, 400)
	q.Admission.AcceptedEpoch = 2
	current.expect(t, s, "apply", "apply", q, 503)
	if more, _ := current.effects(t, second.Decision); more != 0 {
		t.Fatal("旧未执行批准被复活")
	}
	var active bool
	if err := current.db.QueryRow("SELECT status='active' FROM api_keys WHERE id=$1", s.RemoteKey).Scan(&active); err != nil || active {
		t.Fatal("恢复后旧模型 Key 被启用", err)
	}
}

func checkCorrectionHistoryRejections(t *testing.T, v *correctionWeb, previous map[string]string) {
	t.Helper()
	cfgBytes, err := os.ReadFile(v.config)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if json.Unmarshal(cfgBytes, &cfg) != nil {
		t.Fatal("历史配置无法读取")
	}
	dir := filepath.Dir(v.config)
	historyPath := filepath.Join(dir, cfg["recovery_keys_file"].(string))
	original, err := os.ReadFile(historyPath)
	if err != nil {
		t.Fatal(err)
	}
	// 在同一目录另写待验配置，已打开的控制器仍保有先前核对过的不可变代次集合。
	bad := filepath.Join(dir, "rejected-epoch2.json")
	reject := func() {
		t.Helper()
		raw, _ := json.Marshal(cfg)
		if e := os.WriteFile(bad, raw, 0600); e != nil {
			t.Fatal(e)
		}
		c, closePools, e := metonentry.OpenCorrectionControl(bad)
		closePools()
		if e == nil || c != nil {
			t.Fatal("缺失、错摘要或退役 ID 的恢复资料放行")
		}
	}
	delete(cfg, "recovery_keys_file")
	delete(cfg, "recovery_keys_sha256")
	reject()
	cfg["recovery_keys_file"] = filepath.Base(historyPath)
	cfg["recovery_keys_sha256"] = strings.Repeat("0", 64)
	reject()
	for _, change := range []func(*service.CorrectionKeyHistory){
		func(h *service.CorrectionKeyHistory) { h.Generations = h.Generations[1:] },
		func(h *service.CorrectionKeyHistory) { h.Generations[0].ReadID = v.ids["apply"] },
		func(h *service.CorrectionKeyHistory) { h.Generations[1].ReadID = previous["read"] },
		func(h *service.CorrectionKeyHistory) { h.Source = "other" },
	} {
		var h service.CorrectionKeyHistory
		if json.Unmarshal(original, &h) != nil {
			t.Fatal("历史输入有误")
		}
		change(&h)
		material, _ := json.Marshal(h)
		sum := sha256.Sum256(material)
		cfg["recovery_keys_sha256"] = hex.EncodeToString(sum[:])
		cfg["recovery_keys_file"] = "bad-history.json"
		if e := os.WriteFile(filepath.Join(dir, "bad-history.json"), material, 0600); e != nil {
			t.Fatal(e)
		}
		reject()
	}
	const otherRole = "METON_MANAGED_RESULT_APPLY_KEY_ID"
	originalRole := os.Getenv(otherRole)
	t.Setenv(otherRole, previous["read"])
	common, closePools, e := metonentry.OpenCorrectionControl(v.config)
	closePools()
	if e == nil || common != nil {
		t.Fatal("退役读身份被重新分配给另一托管用途")
	}
	s := v.accounts["main"]
	q := v.request(s, correctionSelection(), "resolution")
	q.Epoch = 2
	v.expect(t, s, "resolution", "read", q, 503)
	t.Setenv(otherRole, originalRole)
}

/** 审核、执行和读取不得兼任原裸函数或表读取权限。 */
func TestCorrectionHTTPConfigurationPostgres(t *testing.T) {
	v := newCorrectionWeb(t, 1, nil)
	for _, sql := range [][2]string{
		{"GRANT SELECT ON public.scoped_admin_api_keys TO s2_http_correction_read", "REVOKE SELECT ON public.scoped_admin_api_keys FROM s2_http_correction_read"},
		{"GRANT EXECUTE ON FUNCTION " + metonentry.CorrectionApplyFunction + " TO s2_http_correction_read", "REVOKE EXECUTE ON FUNCTION " + metonentry.CorrectionApplyFunction + " FROM s2_http_correction_read"},
	} {
		if _, err := v.db.Exec(sql[0]); err != nil {
			t.Fatal(err)
		}
		control, closePools, err := metonentry.OpenCorrectionControl(v.config)
		closePools()
		if _, undo := v.db.Exec(sql[1]); undo != nil {
			t.Fatal(undo)
		}
		if err == nil || control != nil {
			t.Fatal("多余数据库权限放行")
		}
	}
	t.Setenv("METON_MANAGED_CORRECTION_READ_KEY_ID", v.ids["apply"])
	control, closePools, err := metonentry.OpenCorrectionControl(v.config)
	closePools()
	if err == nil || control != nil {
		t.Fatal("审核、执行或读身份混用")
	}
}
