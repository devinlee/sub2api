//go:build meton_managed && operations_correction_integration

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

type operationsCorrectionFixture struct {
	Origin, Foreign metonfee.Origin
	Key             OperationsCorrectionKey
	Gift, Purchase  string
}

func correctionFixture(t *testing.T, scenario string) operationsCorrectionFixture {
	t.Helper()
	var scenarios map[string]operationsCorrectionFixture
	raw, err := os.ReadFile(os.Getenv("METON_CORRECTION_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &scenarios) != nil {
		t.Fatal("无法读取隔离来源输入", err)
	}
	s := scenarios[scenario]
	if !s.Origin.Valid() || !s.Foreign.Valid() || !s.Key.valid() {
		t.Fatal("缺少隔离来源对象")
	}
	t.Setenv("METON_MANAGED_ENVIRONMENT", s.Origin.Environment)
	t.Setenv("METON_MANAGED_SOURCE", s.Origin.Source)
	t.Setenv("METON_MANAGED_EPOCH", "1")
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s2-source-v1")
	return s
}

func correctionPool(t *testing.T, role string) *TextLedger {
	t.Helper()
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

/** 用隔离来源三个真实数据库身份，证明执行只认冻结的批准，丢回包仍查原流水。 */
func TestOperationsCorrectionReceiptPostgres(t *testing.T) {
	s := correctionFixture(t, "authority")
	reviewer := correctionPool(t, "s2_correction_reviewer")
	executor := correctionPool(t, "s2_correction_executor")
	reader := correctionPool(t, "s2_correction_observer")
	ctx := t.Context()
	now := time.Now().UTC()
	permit := now.Add(22 * time.Second)
	a := OperationsCorrectionApproval{Sources: []CorrectionSource{{s.Purchase, "1.25000000"}, {s.Gift, "0.50000000"}},
		ValidUntil: now.Add(5 * time.Minute)}
	if _, err := reader.FindOperationsCorrection(ctx, s.Origin, s.Key); err == nil {
		t.Fatal("查无被误报已执行")
	}
	if _, err := reader.ApproveOperationsCorrection(ctx, s.Origin, s.Key, a, permit); err == nil {
		t.Fatal("读身份批准资金")
	}
	approved, err := reviewer.ApproveOperationsCorrection(ctx, s.Origin, s.Key, a, permit)
	if err != nil || approved.State != "approved" || approved.Journal != nil || approved.Approval.Amount != "1.75000000" {
		t.Fatal("原批准不符", err)
	}
	if _, err := reviewer.ApplyOperationsCorrection(ctx, s.Origin, s.Key, permit); err == nil {
		t.Fatal("审核身份执行资金")
	}
	applied, err := executor.ApplyOperationsCorrection(ctx, s.Origin, s.Key, permit)
	if err != nil || applied.State != "applied" || applied.Journal == nil {
		t.Fatal("原执行未取得流水", err)
	}
	got, err := reader.FindOperationsCorrection(ctx, s.Origin, s.Key)
	if err != nil || !reflect.DeepEqual(got, applied) {
		t.Fatal("只读查询未取回原执行", err)
	}
	repeat, err := executor.ApplyOperationsCorrection(ctx, s.Origin, s.Key, permit)
	if err != nil || !reflect.DeepEqual(repeat, applied) {
		t.Fatal("重复执行未返回原凭证", err)
	}
	if _, err := reader.FindOperationsCorrection(ctx, s.Foreign, s.Key); err == nil {
		t.Fatal("其他账号读取原案")
	}
	wire, _ := json.Marshal(applied)
	mutations := []func(*OperationsCorrectionResult){
		func(r *OperationsCorrectionResult) { r.Approval.Origin.Account = uuid.NewString() },
		func(r *OperationsCorrectionResult) { r.CaseID = uuid.NewString() },
		func(r *OperationsCorrectionResult) { r.AttemptID = uuid.NewString() },
		func(r *OperationsCorrectionResult) { r.ApprovalDigest = "" },
		func(r *OperationsCorrectionResult) { r.Generation++ },
		func(r *OperationsCorrectionResult) { r.Epoch++ },
		func(r *OperationsCorrectionResult) { r.State = "approved" },
		func(r *OperationsCorrectionResult) { r.ValidUntil = time.Time{} },
		func(r *OperationsCorrectionResult) { r.Approval.Version++ },
		func(r *OperationsCorrectionResult) { r.Approval.Sources[0].Amount = "4.00000000" },
		func(r *OperationsCorrectionResult) { r.Journal = nil },
	}
	for index, mutate := range mutations {
		var changed OperationsCorrectionResult
		_ = json.Unmarshal(wire, &changed)
		mutate(&changed)
		forged, _ := json.Marshal(changed)
		if _, err := decodeOperationsCorrection(forged, s.Origin, s.Key, 1, true); err == nil {
			t.Fatal("接受了篡改或残缺的资金回执", index)
		}
	}
	if _, err := executor.ApplyOperationsCorrection(ctx, s.Origin, s.Key, now.Add(-time.Second)); err == nil {
		t.Fatal("过期许可执行")
	}
	t.Setenv("METON_MANAGED_EPOCH", "2")
	if _, err := reader.FindOperationsCorrection(ctx, s.Origin, s.Key); err == nil {
		t.Fatal("旧连接交付新代次回执")
	}
	if err := os.WriteFile(os.Getenv("METON_CORRECTION_RECEIPT"), wire, 0600); err != nil {
		t.Fatal(err)
	}
}

/** 真实 PostgreSQL 的空裁决、待返裁决和两种批次穿过强类型分页接口。 */
func TestOperationsCorrectionBasisPostgres(t *testing.T) {
	s := correctionFixture(t, "basis")
	reader := correctionPool(t, "s2_correction_basis_read")
	reviewer := correctionPool(t, "s2_correction_reviewer")
	ctx := t.Context()
	first, err := reader.ReadOperationsCorrectionBasis(ctx, s.Origin, s.Key.Item, s.Key.Basis, 1, nil)
	if err != nil || first.Next == nil || len(first.Rows) != 1 {
		t.Fatal("首批未返回带归属的游标", err)
	}
	last, err := reader.ReadOperationsCorrectionBasis(ctx, s.Origin, s.Key.Item, s.Key.Basis, 1, first.Next)
	if err != nil || last.Next != nil || len(last.Rows) != 1 || first.Rows[0].CreditEvent >= last.Rows[0].CreditEvent {
		t.Fatal("续页重复或遗漏原批次", err)
	}
	if _, err = reader.ReadOperationsCorrectionBasis(ctx, s.Foreign, s.Key.Item, s.Key.Basis, 1, first.Next); err == nil {
		t.Fatal("其他账号续读原分页")
	}
	now := time.Now()
	_, err = reviewer.ApproveOperationsCorrection(ctx, s.Origin, s.Key, OperationsCorrectionApproval{
		Sources: []CorrectionSource{{s.Purchase, "1.00000000"}}, ValidUntil: now.Add(5 * time.Minute)}, now.Add(20*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reader.ReadOperationsCorrectionBasis(ctx, s.Origin, s.Key.Item, s.Key.Basis, 1, first.Next); err == nil {
		t.Fatal("旧分页在新批准出现后仍可续读")
	}
	page, err := reader.ReadOperationsCorrectionBasis(ctx, s.Origin, s.Key.Item, s.Key.Basis, 64, nil)
	if err != nil || len(page.Rows) != 2 || page.Snapshot.Decision == nil || *page.Snapshot.Decision != s.Key.Decision || page.Snapshot.Applied {
		t.Fatal("新裁决的原来源分页不符", err)
	}
	for _, row := range page.Rows {
		if row.CreditEvent == s.Purchase && (row.Returned != "0.00000000" || row.PendingApproved != "1.00000000") {
			t.Fatal("待执行被当成已返还")
		}
	}
	wire, _ := json.Marshal(page)
	mutations := []func(*CorrectionBasisPage){
		func(p *CorrectionBasisPage) { p.Snapshot.Origin.User = uuid.NewString() },
		func(p *CorrectionBasisPage) { p.Snapshot.Epoch++ },
		func(p *CorrectionBasisPage) { p.Funded = "1.00000000" },
		func(p *CorrectionBasisPage) { p.Rows[0].Returned = "9.00000000" },
		func(p *CorrectionBasisPage) { p.Rows[0].Kind = "refund" },
		func(p *CorrectionBasisPage) { p.Rows[1].CreditEvent = p.Rows[0].CreditEvent },
		func(p *CorrectionBasisPage) { p.Next = first.Next },
	}
	for index, mutate := range mutations {
		var changed CorrectionBasisPage
		_ = json.Unmarshal(wire, &changed)
		mutate(&changed)
		if changed.valid(s.Origin, s.Key.Item, s.Key.Basis, 1, 64, nil) {
			t.Fatal("接受了篡改的原批次分页", index)
		}
	}
}
