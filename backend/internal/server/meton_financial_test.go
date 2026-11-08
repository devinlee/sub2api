//go:build unit && meton_managed

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

/** 托管入口只增加固定读取路径，实际工厂缺配置关闭、错误配置拒绝。 */
func TestFinancialManagedIngress(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(metonManagedIngress())
	path := "/api/v1/admin" + metonmodel.FinancialRoute
	r.GET(path, func(c *gin.Context) { c.Status(204) })
	r.POST(path, func(c *gin.Context) { c.Status(204) })
	for method, status := range map[string]int{"GET": 204, "POST": 403} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(method, path, nil))
		if w.Code != status {
			t.Fatal("观察入口范围不符", method, w.Code)
		}
	}
	for _, name := range []string{"RESULT", "SHORTFALL", "CORRECTION", "FINANCIAL"} {
		t.Setenv("METON_MANAGED_"+name+"_CONFIG", "")
	}
	v, err := ProvideMetonResultControl(nil)
	if err != nil || v.Financial != nil {
		t.Fatal("缺配置未关闭")
	}
	v.Close()
	v.Close()
	t.Setenv("METON_MANAGED_FINANCIAL_CONFIG", "not-a-file")
	if _, err = ProvideMetonResultControl(nil); err == nil {
		t.Fatal("错误配置被忽略")
	}
}

type financialBlockedStore struct{ entered, release chan struct{} }

func (s *financialBlockedStore) Read(context.Context, metonmodel.FinancialScope, metonmodel.FinancialAccess) (json.RawMessage, error) {
	close(s.entered)
	<-s.release
	return nil, nil
}
func (s *financialBlockedStore) Confirm(context.Context, metonmodel.FinancialScope, metonmodel.FinancialAccess) error {
	return nil
}

/** 即使依赖不响应取消，名额仍由实际工作持有，迟到结果不能成为有效样本。 */
func TestFinancialLateReadKeepsBudget(t *testing.T) {
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "FINANCIAL_KEY_ID": strings.Repeat("a", 24)} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	source, _ := service.MetonSource()
	s := &financialBlockedStore{make(chan struct{}), make(chan struct{})}
	c, err := service.NewMetonFinancialControl(source, s, 1, 20*time.Millisecond, nil)
	if err != nil {
		t.Fatal(err)
	}
	p := &adminaccess.Principal{KeyID: strings.Repeat("a", 24), CreatorID: 1, KeyRevision: time.Now(), Policy: adminaccess.Policy{GlobalPermissions: []string{metonmodel.FinancialPermission}}}
	key := "adm_sc_" + p.KeyID + "_" + strings.Repeat("b", 64)
	done := make(chan error, 1)
	go func() {
		_, err := c.Observe(t.Context(), p, key, func(context.Context) bool { return true })
		done <- err
	}()
	<-s.entered
	time.Sleep(30 * time.Millisecond)
	started := time.Now()
	if _, err = c.Observe(t.Context(), p, key, func(context.Context) bool { return true }); err == nil || time.Since(started) > 500*time.Millisecond {
		t.Fatal("取消前提前释放真实占用")
	}
	close(s.release)
	if err = <-done; err == nil {
		t.Fatal("迟到样本误报成功")
	}
}

/** PostgreSQL 的时间格式及最大分组都能读取；缺项、重复字段和过期不能变成零值。 */
func TestFinancialSnapshotShape(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Microsecond)
	scope := metonmodel.FinancialScope{Environment: "s2-isolated", Source: "s2-managed", Epoch: 1}
	u := metonmodel.FinancialUnit{Unit: "sample-credit", Held: "7.00000000", GiftHeld: "5.00000000", PurchaseHeld: "2.00000000", RefundHeld: "0.00000000", Shortfall: "0.00000000", Pending: 2}
	v := metonmodel.FinancialObservation{Version: 1, State: "observed", Scope: scope, Snapshot: metonmodel.FinancialTimes{ObservedAt: now, ValidUntil: now.Add(5 * time.Second)}, Accounts: 2, Units: []metonmodel.FinancialUnit{u}}
	raw, _ := json.Marshal(v)
	postgres := strings.ReplaceAll(string(raw), "Z\"", "+00:00\"")
	if _, err := metonmodel.ReadFinancialObservation([]byte(postgres), scope, now); err != nil {
		t.Fatal("合法数据库 UTC 格式被拒")
	}
	for _, bad := range []string{
		strings.Replace(postgres, `"unknown_fees":0,`, "", 1),
		strings.Replace(postgres, `"unknown_fees":0`, `"unknown_fees":null`, 1),
		strings.Replace(postgres, `"version":1`, `"version":1,"version":1`, 1),
		strings.Replace(postgres, `"accounts":2`, `"accounts":2,"user_id":"private"`, 1),
		strings.Replace(postgres, `"held":"7.00000000"`, `"held":"7.00000001"`, 1),
	} {
		if _, err := metonmodel.ReadFinancialObservation([]byte(bad), scope, now); err == nil {
			t.Fatal("不完整或不一致样本被放行")
		}
	}
	if _, err := metonmodel.ReadFinancialObservation(raw, scope, now.Add(5*time.Second)); err == nil {
		t.Fatal("过期样本被放行")
	}
	for i := 1; i < 16; i++ {
		row := u
		row.Unit = fmt.Sprintf("unit-%03d-%s", i, strings.Repeat("x", 110))
		row.Held = strings.Repeat("9", 30) + ".00000000"
		row.GiftHeld, row.PurchaseHeld = row.Held, "0.00000000"
		row.RefundHeld, row.Shortfall = row.Held, row.Held
		v.Units = append(v.Units, row)
	}
	raw, _ = json.Marshal(v)
	if len(raw) <= 8192 {
		t.Fatal("最大合法样本没有覆盖原 8 KiB 边界", len(raw))
	}
	if _, err := metonmodel.ReadFinancialObservation(raw, scope, now); err != nil {
		t.Fatal("16 个单位被旧 8 KiB 结果限制拒绝", len(raw), err)
	}
	v.Units = append(v.Units, u)
	raw, _ = json.Marshal(v)
	if _, err := metonmodel.ReadFinancialObservation(raw, scope, now); err == nil {
		t.Fatal("超限样本被截断接受")
	}
}
