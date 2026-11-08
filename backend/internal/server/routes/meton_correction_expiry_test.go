//go:build unit && meton_managed && correction_http_integration

package routes

import (
	"encoding/json"
	"testing"
	"time"
)

/** 四个原请求都在数据库等账号锁时拒绝第五个；实际管理密钥先于客户端期限到期，原资金保持待执行。 */
func TestCorrectionHTTPExpiryPostgres(t *testing.T) {
	v := newCorrectionWeb(t, 1, nil)
	s := v.accounts["main"]
	k := correctionSelection()
	q := v.request(s, k, "approve")
	past := q
	past.UntilMS = time.Now().Add(-time.Second).UnixMilli()
	v.expect(t, s, "approve", "approve", past, 503)
	long := q
	long.UntilMS = time.Now().Add(time.Minute).UnixMilli()
	v.expect(t, s, "approve", "approve", long, 503)
	v.expect(t, s, "approve", "approve", q, 200)
	lock, err := v.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback()
	if _, err = lock.Exec("SELECT id FROM users WHERE id=$1 FOR UPDATE", s.RemoteUser); err != nil {
		t.Fatal(err)
	}
	var end time.Time
	if err = v.db.QueryRow("UPDATE scoped_admin_api_keys SET expires_at=clock_timestamp()+interval '5 seconds',updated_at=clock_timestamp() WHERE id=$1 RETURNING expires_at", v.ids["apply"]).Scan(&end); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(v.request(s, k, "apply"))
	done := make(chan correctionReply, 4)
	for i := 0; i < 4; i++ {
		go func() { done <- v.call(s, "apply", v.tokens["apply"], raw, nil) }()
	}
	seen := false
	for time.Now().Before(end) {
		var n int
		if err = v.db.QueryRow("SELECT count(*) FROM pg_stat_activity WHERE usename='s2_http_correction_apply' AND wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid))>0").Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 4 {
			seen = true
			break
		}
		time.Sleep(15 * time.Millisecond)
	}
	if !seen {
		t.Fatal("没有四个实际在等锁的受限调用")
	}
	v.expect(t, s, "resolution", "read", v.request(s, k, "resolution"), 503)
	select {
	case <-done:
		t.Fatal("容量拒绝之前已有调用结束")
	default:
	}
	for i := 0; i < 4; i++ {
		select {
		case r := <-done:
			if r.code != 503 || r.err != nil {
				t.Fatal("密钥到期后仍返回资金结果", r.code, r.err)
			}
		case <-time.After(8 * time.Second):
			t.Fatal("原密钥到期后仍卡在账号锁")
		}
	}
	if err = lock.Rollback(); err != nil {
		t.Fatal(err)
	}
	if n, _ := v.effects(t, k.Decision); n != 0 {
		t.Fatal("密钥到期仍提交资金")
	}
	if r := v.call(s, "apply", v.tokens["apply"], raw, nil); r.code != 401 {
		t.Fatal("已过期密钥仍能入站", r.code)
	}
	data := v.expect(t, s, "resolution", "read", v.request(s, k, "resolution"), 200)
	var result struct{ State string }
	if json.Unmarshal(data, &result) != nil || result.State != "approved" {
		t.Fatal("原批准状态错误")
	}
}
