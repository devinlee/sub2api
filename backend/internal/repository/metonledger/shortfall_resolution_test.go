//go:build meton_managed && shortfall_integration

package metonledger

import (
	"database/sql"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

/** 实际受限连接证明已覆盖和无效果两种结果；回包丢失只读找回，不新增子命令。 */
func TestShortfallResolutionPostgres(t *testing.T) {
	var input struct {
		Origin, Foreign, Insufficient metonfee.Origin
		Key, InsufficientKey          ShortfallKey
	}
	raw, err := os.ReadFile(os.Getenv("METON_SHORTFALL_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &input) != nil {
		t.Fatal("读取固定差额输入失败", err)
	}
	for k, v := range map[string]string{"METON_MANAGED_ENVIRONMENT": input.Origin.Environment, "METON_MANAGED_SOURCE": input.Origin.Source,
		"METON_MANAGED_EPOCH": "1", "METON_MANAGED_FUNDS_MODE": "s2-source-v1"} {
		t.Setenv(k, v)
	}
	open := func(role string) *TextLedger {
		db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = db.Close() })
		l, err := NewTextLedger(db)
		if err != nil {
			t.Fatal(err)
		}
		return l
	}
	executor, reader := open("s2_shortfall_execute"), open("s2_shortfall_read")
	ctx := t.Context()
	if _, err := reader.FindShortfall(ctx, input.Origin, input.Key); err == nil {
		t.Fatal("不存在的结论被视为明确未执行")
	}
	if _, err := reader.CoverShortfall(ctx, input.Origin, input.Key, time.Now().Add(25*time.Second)); err == nil {
		t.Fatal("只读身份执行资金")
	}
	for _, until := range []time.Time{time.Now().Add(-time.Second), time.Now().Add(time.Minute)} {
		if _, err := executor.CoverShortfall(ctx, input.Origin, input.Key, until); err == nil {
			t.Fatal("过期或过长授权可执行")
		}
	}
	r, err := executor.CoverShortfall(ctx, input.Origin, input.Key, time.Now().Add(25*time.Second))
	if err != nil || r == nil || r.State != "covered" || r.Result.Funded != "5.00000000" {
		t.Fatal("原差额结清失败", err)
	}
	found, err := reader.FindShortfall(ctx, input.Origin, input.Key)
	if err != nil || !reflect.DeepEqual(found, r) {
		t.Fatal("提交丢回包后未读回原结论", err)
	}
	if _, err := reader.FindShortfall(ctx, input.Foreign, input.Key); err == nil {
		t.Fatal("另一账号取得差额回执")
	}
	wrong := input.Key
	wrong.AttemptID = uuid.NewString()
	if _, err := reader.FindShortfall(ctx, input.Origin, wrong); err == nil {
		t.Fatal("错误 Attempt 被接受")
	}
	stable, err := executor.CoverShortfall(ctx, input.Origin, input.Key, time.Now().Add(25*time.Second))
	if err != nil || !reflect.DeepEqual(stable, r) {
		t.Fatal("原命令重放不稳定", err)
	}
	insufficient, err := executor.CoverShortfall(ctx, input.Insufficient, input.InsufficientKey, time.Now().Add(25*time.Second))
	if err != nil || insufficient == nil || insufficient.State != "funds_unavailable" || insufficient.Result != nil {
		t.Fatal("不足未区分确定无效果", err)
	}
	again, err := reader.FindShortfall(ctx, input.Insufficient, input.InsufficientKey)
	if err != nil || !reflect.DeepEqual(again, insufficient) {
		t.Fatal("原未执行结论未保存", err)
	}
	wire, _ := json.Marshal(r)
	mutations := map[string]func(*ShortfallResolution){
		"command":       func(v *ShortfallResolution) { v.CommandID = uuid.NewString() },
		"case":          func(v *ShortfallResolution) { v.CaseID = uuid.NewString() },
		"attempt":       func(v *ShortfallResolution) { v.AttemptID = uuid.NewString() },
		"approval":      func(v *ShortfallResolution) { v.ApprovalDigest = "" },
		"basis_owner":   func(v *ShortfallResolution) { v.Basis.Report.Origin.User = uuid.NewString() },
		"basis_event":   func(v *ShortfallResolution) { v.Basis.Report.Item.EventID = uuid.NewString() },
		"missing":       func(v *ShortfallResolution) { v.Missing = "1.00000000" },
		"available":     func(v *ShortfallResolution) { v.AvailableBefore = "-1.00000000" },
		"unknown":       func(v *ShortfallResolution) { v.State = "unknown" },
		"no_result":     func(v *ShortfallResolution) { v.Result = nil },
		"result_owner":  func(v *ShortfallResolution) { v.Result.Report.Origin.Account = uuid.NewString() },
		"result_amount": func(v *ShortfallResolution) { v.Result.Report.Item.Amount = "9.00000000" },
		"result_prior":  func(v *ShortfallResolution) { v.Result.Report.Item.PreviousEventID = nil },
		"result_price":  func(v *ShortfallResolution) { v.Result.Report.Item.PriceVersion = "v2" },
		"result_gap":    func(v *ShortfallResolution) { v.Result.Uncovered = "1.00000000" },
		"result_source": func(v *ShortfallResolution) { v.Result.Sources[0].CreditEvent = "not-a-source" },
	}
	for name, mutate := range mutations {
		var changed ShortfallResolution
		_ = json.Unmarshal(wire, &changed)
		mutate(&changed)
		if verifyShortfall(changed, input.Origin, input.Key) == nil {
			t.Fatal("篡改回执被接受", name)
		}
	}
	var extra map[string]any
	_ = json.Unmarshal(wire, &extra)
	extra["amount_override"] = "0.00000000"
	forged, _ := json.Marshal(extra)
	if _, err := decodeShortfall(forged, input.Origin, input.Key); err == nil {
		t.Fatal("额外资金字段被接受")
	}
	t.Setenv("METON_MANAGED_EPOCH", "2")
	if _, err := executor.CoverShortfall(ctx, input.Origin, input.Key, time.Now().Add(25*time.Second)); err == nil {
		t.Fatal("旧配置连接仍可执行")
	}
	if _, err := reader.FindShortfall(ctx, input.Origin, input.Key); err == nil {
		t.Fatal("旧配置连接交付当前权限回执")
	}
	if err := os.WriteFile(os.Getenv("METON_SHORTFALL_EXPORT"), wire, 0600); err != nil {
		t.Fatal(err)
	}
}
