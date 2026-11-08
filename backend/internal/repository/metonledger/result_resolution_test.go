//go:build meton_managed && resolution_integration

package metonledger

import (
	"database/sql"
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

/** 新接缝用实际隔离 SQL 验证凭证登记、原号找回、独立执行和提交后的严格回执校验。 */
func TestResultResolutionPostgres(t *testing.T) {
	var input struct {
		Origin, Foreign metonfee.Origin
		Key             ResultProofKey
		Execution       ResultResolutionKey
		Spec            metonexecution.Record
		Observation     metonresult.Snapshot
	}
	raw, err := os.ReadFile(os.Getenv("METON_RESOLUTION_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &input) != nil {
		t.Fatal("读取本轮固定输入失败", err)
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
	observer, executor, reader := open("s2_resolution_observe"), open("s2_resolution_apply"), open("s2_resolution_read")
	ctx := t.Context()
	if _, err := executor.ApplyResultProof(ctx, input.Origin, input.Execution); err == nil {
		t.Fatal("没有供应证据也执行")
	}
	p, err := observer.RecordResultProof(ctx, input.Origin, input.Key, input.Spec, input.Observation)
	if err != nil {
		t.Fatal("登记原凭证", err)
	}
	// 登记的回复可以丢失；独立查询只读找回相同事实，不重交或另造证据编号。
	q, err := reader.FindResultProof(ctx, input.Origin, input.Key)
	if err != nil || !reflect.DeepEqual(p, q) {
		t.Fatal("原凭证只读找回", err)
	}
	if _, err := reader.FindResultProof(ctx, input.Foreign, input.Key); err == nil {
		t.Fatal("凭证可跨账户读取")
	}
	if _, err := observer.ApplyResultProof(ctx, input.Origin, input.Execution); err == nil {
		t.Fatal("观察身份兼任执行")
	}
	if _, err := executor.RecordResultProof(ctx, input.Origin, input.Key, input.Spec, input.Observation); err == nil {
		t.Fatal("执行身份可制作证据")
	}
	r, err := executor.ApplyResultProof(ctx, input.Origin, input.Execution)
	if err != nil || r.Result.Posting.Funded != "2.00000000" || r.Result.Posting.Uncovered != "0.00000000" {
		t.Fatal("原结算", err)
	}
	found, err := reader.FindResultResolution(ctx, input.Origin, input.Execution)
	if err != nil || !reflect.DeepEqual(r, found) {
		t.Fatal("执行丢回复后不能读回原结案", err)
	}
	wrong := input.Execution
	wrong.AttemptID = uuid.NewString()
	if _, err := reader.FindResultResolution(ctx, input.Origin, wrong); err == nil {
		t.Fatal("错误执行号得到另一执行回执")
	}
	if _, err := executor.ApplyResultProof(ctx, input.Origin, wrong); err == nil {
		t.Fatal("更换执行号重新结算")
	}
	stable, err := executor.ApplyResultProof(ctx, input.Origin, input.Execution)
	if err != nil || !reflect.DeepEqual(stable, r) {
		t.Fatal("原执行未幂等", err)
	}
	wire, _ := json.Marshal(r)
	for name, mutate := range map[string]func(*ResultResolution){
		"owner":        func(v *ResultResolution) { v.Origin.User = uuid.NewString() },
		"evidence":     func(v *ResultResolution) { v.EvidenceID = uuid.NewString() },
		"case":         func(v *ResultResolution) { v.CaseID = uuid.NewString() },
		"attempt":      func(v *ResultResolution) { v.AttemptID = uuid.NewString() },
		"approval":     func(v *ResultResolution) { v.ApprovalDigest = "" },
		"prior":        func(v *ResultResolution) { v.PriorEvent = v.Result.EventID },
		"missing_fee":  func(v *ResultResolution) { v.Result.Posting = nil },
		"missing_end":  func(v *ResultResolution) { v.Result.Ending = nil },
		"unknown":      func(v *ResultResolution) { v.Result.Observation = metonresult.Unavailable("responses") },
		"fee_owner":    func(v *ResultResolution) { v.Result.Posting.Report.Origin.User = uuid.NewString() },
		"partial_read": func(v *ResultResolution) { v.Result.Observation.ReadEnd = "closed" },
	} {
		var changed ResultResolution
		_ = json.Unmarshal(wire, &changed)
		mutate(&changed)
		if verifyResultResolution(changed, input.Origin, input.Execution) == nil {
			t.Fatal("回执误放行", name)
		}
	}
	t.Setenv("METON_MANAGED_EPOCH", "2")
	if _, err := executor.ApplyResultProof(ctx, input.Origin, input.Execution); err == nil {
		t.Fatal("配置已换代，旧连接仍可执行")
	}
	if _, err := reader.FindResultResolution(ctx, input.Origin, input.Execution); err == nil {
		t.Fatal("旧连接将结果作为当前权限交付")
	}
	if err := os.WriteFile(os.Getenv("METON_RESOLUTION_EXPORT"), wire, 0600); err != nil {
		t.Fatal(err)
	}
}
