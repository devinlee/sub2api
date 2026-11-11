package service

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

/** 退款原意图可跨原归档只读接续，字段升级不能放开私有材料、异号或执行权限。 */
func TestCashArchiveOriginalKeepsPublicRefundIntent(t *testing.T) {
	ref := uuid.NewString()
	key := "refund/" + ref
	digest := strings.Repeat("a", 64)
	id := CashArchiveIdentity{Environment: "s3-isolated", Source: "history-fixture", Epoch: 1, ScopeKey: digest, KeyRef: uuid.New(), ArchiveSystem: "32400002"}
	q := CashArchiveRequest{OriginalKey: &key, Version: 1, Environment: id.Environment, Source: id.Source, Epoch: 1, ScopeKey: digest, Size: 1}
	no := false
	x := &cashOperationsItem{Key: key, BasisDigest: digest}
	x.Original.Kind, x.Original.Ref = "refund", ref
	x.Original.Value = map[string]json.RawMessage{"category": json.RawMessage(`"refund_held"`)}
	v := cashArchiveOriginalObservation{Format: 1, State: "observed", ScopeKey: digest, OriginalKey: key, ArchiveBasisDigest: &digest,
		Original: x, ObservedAt: time.Now(), FinancialAuthority: &no, ExecutionAuthorized: &no, BasisDigest: digest,
		Scope: CashArchiveOriginalScope{Deployment: id.Environment, Source: id.Source, Epoch: 1, KeyRef: id.KeyRef,
			SourceSystem: "32400001", InboxSystem: id.ArchiveSystem, Channel: "wechatpay", CashEnvironment: "isolated", Merchant: "3240001"}}
	if !v.matches(id, q) {
		t.Fatal("旧公开退款资料应保持可读")
	}
	intent, err := json.Marshal(uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	x.Original.Value["intent"] = intent
	if !v.matches(id, q) {
		t.Fatal("当前来源的原确认意图被拒绝")
	}
	for _, value := range []json.RawMessage{json.RawMessage(`{"secret":"hidden"}`), json.RawMessage(`["hidden"]`)} {
		x.Original.Value["intent"] = value
		if v.matches(id, q) {
			t.Fatal("新增字段放过嵌套材料")
		}
	}
	x.Original.Value["intent"] = intent
	x.Original.Value["privateProof"] = json.RawMessage(`"hidden"`)
	if v.matches(id, q) {
		t.Fatal("私有字段进入公开原观察")
	}
	delete(x.Original.Value, "privateProof")
	x.Original.Ref = uuid.NewString()
	if v.matches(id, q) {
		t.Fatal("另一原事项被接受")
	}
	x.Original.Ref = ref
	yes := true
	v.ExecutionAuthorized = &yes
	if v.matches(id, q) {
		t.Fatal("只读原观察不能授予执行权")
	}
}
