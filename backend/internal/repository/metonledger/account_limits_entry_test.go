//go:build meton_managed && account_limits_integration && dispatch_integration

package metonledger

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/google/uuid"
)

/** 两个受信文本入口都核对保护；只新增实际预占接缝，不重做直接入口与八连接争用。 */
func TestAccountAdmissionEntryGuardsPostgres(t *testing.T) {
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s2-source-v1")
	t.Setenv("METON_MANAGED_ENVIRONMENT", "s2-isolated")
	t.Setenv("METON_MANAGED_SOURCE", "s2-managed")
	t.Setenv("METON_MANAGED_EPOCH", "1")
	var sample struct {
		Context      metondispatch.Context
		Key          SessionKey
		Secret       string
		SourceMarker string
	}
	raw, err := os.ReadFile(os.Getenv("METON_ACCOUNT_ENTRY_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &sample) != nil || sample.Key.ID < 1 || sample.SourceMarker == "" {
		t.Fatal("missing explicit account entry fixture", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	open := func(role string) *sql.DB {
		db, e := sql.Open("postgres", "host=127.0.0.1 port=5432 dbname=s2_grants sslmode=disable user="+role)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { db.Close() })
		return db
	}
	admin := open("postgres")
	reader, err := NewTextLedger(open("s2_read"))
	if err != nil {
		t.Fatal(err)
	}
	exec := func(query string) {
		if _, e := admin.ExecContext(ctx, query); e != nil {
			t.Fatal(e)
		}
	}
	signer := dispatchtest.New(t)
	body := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic"}`)
	profile, err := metonexecution.NewProfile(metonexecution.Spec{Version: "fixture-window-v1", Protocol: "responses", Model: "meton-s2-text-fixture",
		WireProtocol: "responses", WireModel: "meton-s2-text-fixture", Target: "https://models.invalid/v1/responses", MaxBodyBytes: 4096, InputWindow: 1024, OutputWindow: 128})
	if err != nil {
		t.Fatal(err)
	}
	pathsRun := 0
	for _, path := range []string{"transport", "execution"} {
		t.Run(path, func(t *testing.T) {
			pathsRun++
			role := "s2_transport_reserve"
			if path == "execution" {
				role = "s2_execution_reserve"
			}
			writer, e := NewTextLedger(open(role))
			if e != nil {
				t.Fatal(e)
			}
			verified := map[string]*metondispatch.Verified{}
			invoke := func(operation string) (*Hold, error) {
				v := verified[operation]
				if v == nil {
					c := sample.Context
					c.OperationID, c.InputDigest, c.ValidUntilMS = operation, dispatchtest.Hash(body), time.Now().Add(25*time.Second).UnixMilli()
					// 两条独立原调用不能复用同一派发号；协议路径已通过，增量只修正执行路径样本。
					if path == "execution" {
						c.Worker, c.Dispatch = uuid.NewString(), uuid.NewString()
					}
					v = signer.Verify(t, c, body, []byte(sample.Secret))
					verified[operation] = v
				}
				c := v.Context()
				if path == "transport" {
					return writer.ReserveTransport(ctx, v, sample.Key, Estimate{Protocol: c.Protocol, Model: c.Model, Digest: c.InputDigest, DigestVersion: 1, InputBound: 2, OutputBound: 1})
				}
				r, e := http.NewRequestWithContext(ctx, "POST", "https://models.invalid/v1/responses", strings.NewReader(string(body)))
				if e != nil {
					t.Fatal(e)
				}
				q, e := profile.Quote(v, r, body)
				if e != nil {
					t.Fatal(e)
				}
				return writer.ReserveExecution(ctx, v, sample.Key, q)
			}
			call := Call{User: sample.Context.User, Account: sample.Context.Account, SourceMarker: sample.SourceMarker, Caller: sample.Context.Caller, OperationID: uuid.NewString()}
			held, e := invoke(call.OperationID)
			if e != nil || held == nil {
				t.Fatal("valid entry refused", e)
			}
			for _, kind := range []string{"disabled", "missing", "conditional"} {
				t.Run(kind, func(t *testing.T) {
					if kind == "disabled" {
						exec("ALTER TABLE meton_ledger.text_requests DISABLE TRIGGER enforce_text_account_limit")
					} else {
						exec("DROP TRIGGER enforce_text_account_limit ON meton_ledger.text_requests")
						if kind == "conditional" {
							exec("CREATE TRIGGER enforce_text_account_limit BEFORE INSERT ON meton_ledger.text_requests FOR EACH ROW WHEN (false) EXECUTE FUNCTION meton_ledger.enforce_text_account_limit()")
						}
					}
					fresh := call
					fresh.OperationID = uuid.NewString()
					if value, e := invoke(fresh.OperationID); value != nil || e == nil || e.Error() != "managed account admission guard unavailable" {
						t.Fatal("entry bypassed account guard", e)
					}
					if value, e := reader.Find(ctx, fresh); value != nil || !errors.Is(e, sql.ErrNoRows) {
						t.Fatal("rejected entry left an original request", e)
					}
					if value, e := reader.Find(ctx, call); e != nil || value.Origin != held.Origin {
						t.Fatal("original query affected", e)
					}
					if kind == "disabled" {
						exec("ALTER TABLE meton_ledger.text_requests ENABLE TRIGGER enforce_text_account_limit")
					} else {
						if kind == "conditional" {
							exec("DROP TRIGGER enforce_text_account_limit ON meton_ledger.text_requests")
						}
						exec("CREATE TRIGGER enforce_text_account_limit BEFORE INSERT ON meton_ledger.text_requests FOR EACH ROW EXECUTE FUNCTION meton_ledger.enforce_text_account_limit()")
					}
				})
			}
			if value, e := invoke(call.OperationID); e != nil || value.Origin != held.Origin {
				t.Fatal("restored entry failed to reuse original request", e)
			}
		})
	}
	var count int
	if err = admin.QueryRowContext(ctx, "SELECT count(*) FROM meton_ledger.text_requests WHERE source_marker=$1", sample.SourceMarker).Scan(&count); err != nil || pathsRun == 0 || count != pathsRun {
		t.Fatal("entry guards left unexpected requests", count, err)
	}
}
