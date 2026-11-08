//go:build meton_managed && provider_integration

package metonledger

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sync/atomic"
	"testing"
	"time"
)

/** TestOriginalProviderPostgres 将真实 TLS 只读响应接回原未知、独立观察及一次原价结算。 */
func TestOriginalProviderPostgres(t *testing.T) {
	var input struct {
		Owner   metonfee.Origin
		Context map[string]any
		Key     SessionKey
	}
	raw, err := os.ReadFile(os.Getenv("METON_PROVIDER_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &input) != nil {
		t.Fatal("缺少本轮隔离输入", err)
	}
	for k, v := range map[string]string{"METON_MANAGED_ENVIRONMENT": input.Owner.Environment, "METON_MANAGED_SOURCE": input.Owner.Source, "METON_MANAGED_EPOCH": "1", "METON_MANAGED_FUNDS_MODE": "s2-source-v1"} {
		t.Setenv(k, v)
	}
	open := func(role string) (*sql.DB, *TextLedger) {
		db, e := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { _ = db.Close() })
		l, e := NewTextLedger(db)
		if e != nil {
			t.Fatal(e)
		}
		return db, l
	}
	reserve, _ := open("s2_provider_reserve")
	sender, _ := open("s2_resolution_prepare")
	complete, _ := open("s2_resolution_complete")
	_, reader := open("s2_provider_read")
	_, observer := open("s2_resolution_observe")
	_, executor := open("s2_resolution_apply")
	owner, _ := open("postgres")
	var calls atomic.Int32
	var observedAllowed atomic.Bool
	observedAllowed.Store(true)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != "GET" || r.URL.Path != "/v1/responses/resp_original" || r.Header.Get("Authorization") != "Bearer isolated-supplier-key" {
			t.Error("原供应读取改变身份或派发生成")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"resp_original","model":"meton-s2-text-fixture","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2,"input_tokens_details":{"cached_tokens":0}}}`))
	}))
	defer server.Close()
	target := server.URL + "/v1/responses"
	sum := sha256.Sum256([]byte(target))
	spec := metonexecution.Record{Version: 1, Profile: "provider-joint-v1", ProfileHash: hex.EncodeToString(sum[:]), WireProtocol: "responses", WireModel: "meton-s2-text-fixture", TargetHash: hex.EncodeToString(sum[:]), BodyDigest: hex.EncodeToString(sum[:]), InputBound: 2, OutputBound: 1}
	headers := http.Header{"Authorization": []string{"Bearer isolated-supplier-key"}}
	binding, e := metonprovider.Capture(23, headers, "responses", []byte(`{"model":"meton-s2-text-fixture","input":"isolated"}`))
	if e != nil {
		t.Fatal(e)
	}
	// 只有隔离样本建立原未知：正式路径必须在原生发送前由 Admission 和可信 Quote 保存这些事实。
	input.Context["valid_until_ms"] = time.Now().Add(29 * time.Second).UnixMilli()
	contextRaw, _ := json.Marshal(input.Context)
	contextSum := sha256.Sum256(contextRaw)
	contextHash := hex.EncodeToString(contextSum[:])
	frozen, _ := json.Marshal(spec)
	bound, _ := json.Marshal(binding)
	h, e := scanHold(reserve.QueryRowContext(t.Context(), holdColumns+"reserve_provider_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9)", input.Owner.Environment, input.Owner.Source, 1, string(contextRaw), contextHash, "gateway-s2", input.Key.ID, string(frozen), string(bound)))
	if e != nil {
		t.Fatal("原供应预占", e)
	}
	o := h.Origin
	args := []any{o.Environment, o.Source, 1, o.User, o.Account, o.SourceMarker, o.Caller, o.OperationID, o.SourceRequestID}
	var first bool
	e = sender.QueryRowContext(t.Context(), "SELECT meton_ledger.claim_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)", append(append([]any{}, args...), contextHash, input.Key.ID, input.Key.Fingerprint, string(frozen))...).Scan(&first)
	if e != nil || !first {
		t.Fatal("原发送样本", e)
	}
	old := metonresult.Snapshot{FormatVersion: 1, Protocol: "responses", Execution: "unknown", ResponseID: "resp_original", ReadEnd: "read_error", BodySHA256: contextHash}
	encoded, _ := json.Marshal(old)
	var completion json.RawMessage
	e = complete.QueryRowContext(t.Context(), "SELECT meton_ledger.complete_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)", append(append([]any{}, args...), contextHash, string(frozen), string(encoded))...).Scan(&completion)
	if e != nil {
		t.Fatal("首次未知", e)
	}
	if _, e = owner.ExecContext(t.Context(), "UPDATE api_keys SET status='inactive' WHERE id=$1", input.Key.ID); e != nil {
		t.Fatal(e)
	}
	client := server.Client()
	transport := client.Transport.(*http.Transport).Clone()
	transport.TLSClientConfig = transport.TLSClientConfig.Clone()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	transport.TLSClientConfig.RootCAs = roots
	transport.TLSClientConfig.InsecureSkipVerify = false
	client = &http.Client{Transport: transport}
	provider, e := metonprovider.NewReader(client, []string{target}, 1, 2*time.Second)
	if e != nil {
		t.Fatal(e)
	}
	defer provider.Close()
	credentials := func(context.Context, int64) (http.Header, error) { return headers.Clone(), nil }
	guard := func(context.Context) error {
		if !observedAllowed.Load() {
			return errors.New("operator revoked")
		}
		return nil
	}
	evidence := uuid.NewString()
	proof, e := reader.ObserveProvider(t.Context(), o, evidence, provider, credentials, observer, guard)
	if e != nil || proof.Observation.ResponseID != "resp_original" || !proof.Observation.FeeReady || calls.Load() != 1 {
		t.Fatal("原 TLS 响应未进入受限凭证", e, calls.Load())
	}
	replay, e := reader.ObserveProvider(t.Context(), o, evidence, provider, credentials, observer, guard)
	if e != nil || !reflect.DeepEqual(proof, replay) || calls.Load() != 1 {
		t.Fatal("登记重放未找回原凭证", e)
	}
	var fees int
	var held string
	e = owner.QueryRowContext(t.Context(), "SELECT (SELECT count(*) FROM meton_ledger.text_fee_reports WHERE request_id=$1),(SELECT sum(held)::text FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=$2)", o.SourceRequestID, o.SourceMarker).Scan(&fees, &held)
	if e != nil || fees != 0 || held != "3.00000000" {
		t.Fatal("观察提前修改了费用或 H", fees, held, e)
	}
	foreign := o
	foreign.User = uuid.NewString()
	if _, e = reader.ObserveProvider(t.Context(), foreign, evidence, provider, credentials, observer, guard); e == nil || calls.Load() != 1 {
		t.Fatal("原凭证可跨用户查询")
	}
	observedAllowed.Store(false)
	if _, e = reader.ObserveProvider(t.Context(), o, evidence, provider, credentials, observer, guard); e == nil {
		t.Fatal("撤销运营权限后仍交付")
	}
	observedAllowed.Store(true)
	key := ResultResolutionKey{EvidenceID: evidence, CaseID: uuid.NewString(), AttemptID: uuid.NewString(), ApprovalDigest: contextHash}
	resolved, e := executor.ApplyResultProof(t.Context(), o, key)
	if e != nil || resolved.Result.Posting.Funded != "2.00000000" || resolved.Result.Posting.Uncovered != "0.00000000" {
		t.Fatal("原价结算失败", e)
	}
	repeated, e := executor.ApplyResultProof(t.Context(), o, key)
	if e != nil || !reflect.DeepEqual(resolved, repeated) {
		t.Fatal("重复执行改变结案", e)
	}
	var balance string
	var active int
	e = owner.QueryRowContext(t.Context(), "SELECT u.balance::text,(SELECT count(*) FROM meton_ledger.text_fee_reports WHERE request_id=$1),(SELECT count(*) FROM api_keys WHERE id=$2 AND status='active') FROM users u JOIN meton_managed_creations m ON m.remote_user=u.id WHERE m.source_marker=$3", o.SourceRequestID, input.Key.ID, o.SourceMarker).Scan(&balance, &fees, &active)
	if e != nil || balance != "3.00000000" || fees != 1 || active != 0 {
		t.Fatal("结算重复或旧凭据恢复", balance, fees, active, e)
	}
	if _, e = owner.ExecContext(t.Context(), "UPDATE meton_managed_fence SET enabled=false"); e != nil {
		t.Fatal(e)
	}
	if _, e = reader.ObserveProvider(t.Context(), o, uuid.NewString(), provider, credentials, observer, guard); e == nil || calls.Load() != 1 {
		t.Fatal("关闭来源仍查供应")
	}
	if _, e = owner.ExecContext(t.Context(), "UPDATE meton_managed_fence SET enabled=true"); e != nil {
		t.Fatal(e)
	}
	wire, _ := json.Marshal(map[string]any{"origin": o, "proof": proof, "resolution": resolved, "http_get_count": calls.Load(), "model_post_count": 0, "old_key_active": active})
	if e = os.WriteFile(os.Getenv("METON_PROVIDER_EXPORT"), wire, 0600); e != nil {
		t.Fatal(e)
	}
}
