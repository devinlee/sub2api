//go:build meton_managed && supplier_return_integration

package metonledger

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/lib/pq"
)

// TestSupplierReturnPostgres 两个受限身份连同一实际库。成本回执有独立的货币单位。
func TestSupplierReturnPostgres(t *testing.T) {
	var sample struct {
		Origin, Foreign metonfee.Origin
		Item, Report    string
	}
	body, err := os.ReadFile(os.Getenv("METON_SUPPLIER_FIXTURE"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, &sample); err != nil {
		t.Fatal(err)
	}
	open := func(role string) *TextLedger {
		db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { db.Close() })
		ledger, err := NewTextLedger(db)
		if err != nil {
			t.Fatal(err)
		}
		return ledger
	}
	ctx := context.Background()
	writer, reader := open("s2_cost"), open("s2_read")
	key := SupplierReturnKey{sample.Item, sample.Report, "provider.test", "Go/Return-1"}
	proof := SupplierCostReturn{key, "USD", "0.12345678"}
	cost, err := writer.RecordSupplierReturn(ctx, sample.Origin, proof)
	if err != nil || cost.SupplierCostReturn != proof || cost.Origin != sample.Origin {
		t.Fatal("record original cost", err)
	}
	found, err := reader.FindSupplierReturn(ctx, sample.Origin, key)
	if err != nil || *found != *cost {
		t.Fatal("find original cost", err)
	}
	again, err := writer.RecordSupplierReturn(ctx, sample.Origin, proof)
	if err != nil || *again != *found {
		t.Fatal("repeat original cost", err)
	}
	proof.Amount = "1.00000000"
	_, err = writer.RecordSupplierReturn(ctx, sample.Origin, proof)
	var conflict *pq.Error
	if !errors.As(err, &conflict) || conflict.Code != "23505" {
		t.Fatal("changed original cost", err)
	}
	if foreign, err := reader.FindSupplierReturn(ctx, sample.Foreign, key); foreign != nil || !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("foreign cost became visible", err)
	}
	if _, err := reader.RecordSupplierReturn(ctx, sample.Origin, proof); err == nil {
		t.Fatal("read role could write")
	}
	t.Setenv("METON_MANAGED_EPOCH", "2")
	if _, err := writer.RecordSupplierReturn(ctx, sample.Origin, proof); err == nil {
		t.Fatal("old deployment could write")
	}
}
