//go:build meton_managed && account_limits_integration

package metonledger

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

/** 使用同一隔离来源库的窄运行身份；保护被改坏只阻止新受理，原事项始终可按原归属查询。 */
func TestAccountAdmissionGuardPostgres(t *testing.T) {
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s2-source-v1")
	t.Setenv("METON_MANAGED_ENVIRONMENT", "s2-isolated")
	t.Setenv("METON_MANAGED_SOURCE", "s2-managed")
	t.Setenv("METON_MANAGED_EPOCH", "1")
	var sample struct {
		Call Call
		Key  SessionKey
	}
	raw, err := os.ReadFile(os.Getenv("METON_ACCOUNT_LIMIT_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &sample) != nil || sample.Call.User == "" || sample.Key.ID < 1 {
		t.Fatal("missing explicit account limit fixture", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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
	writer, err := NewTextLedger(open("s2_reserve"))
	if err != nil {
		t.Fatal(err)
	}
	reader, err := NewTextLedger(open("s2_read"))
	if err != nil {
		t.Fatal(err)
	}
	exec := func(text string) {
		if _, e := admin.ExecContext(ctx, text); e != nil {
			t.Fatal(e)
		}
	}
	q := Estimate{Protocol: "responses", Model: "limits-go", Digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", DigestVersion: 1, InputBound: 2, OutputBound: 1}
	held, err := writer.Reserve(ctx, sample.Call, sample.Key, q)
	if err != nil || held == nil {
		t.Fatal("installed guard refused the valid original admission", err)
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
			fresh := sample.Call
			fresh.OperationID = uuid.NewString()
			if value, e := writer.Reserve(ctx, fresh, sample.Key, q); value != nil || e == nil {
				t.Fatal("missing or changed guard admitted a new call")
			}
			if value, e := reader.Find(ctx, fresh); value != nil || !errors.Is(e, sql.ErrNoRows) {
				t.Fatal("refused admission left a source request", e)
			}
			if value, e := reader.Find(ctx, sample.Call); e != nil || value.Origin != held.Origin {
				t.Fatal("new-admission gate blocked the original read", e)
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
	fresh := sample.Call
	fresh.OperationID = uuid.NewString()
	if value, e := writer.Reserve(ctx, fresh, sample.Key, q); e != nil || value == nil || value.Origin.SourceRequestID == held.Origin.SourceRequestID {
		t.Fatal("restored guard refused a distinct valid call", e)
	}
	var count int
	if err = admin.QueryRowContext(ctx, "SELECT count(*) FROM meton_ledger.text_requests WHERE source_marker=$1", sample.Call.SourceMarker).Scan(&count); err != nil || count != 2 {
		t.Fatal("unexpected source admission count", count, err)
	}
}
