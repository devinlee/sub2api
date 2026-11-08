//go:build meton_managed && reservation_integration

package metonledger

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

// TestTextLedgerPostgres 经四种独立的来源库身份读取、预占、取消和领取，不使用 Go 仓储模拟件。
func TestTextLedgerPostgres(t *testing.T) {
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s2-source-v1")
	t.Setenv("METON_MANAGED_ENVIRONMENT", "s2-isolated")
	t.Setenv("METON_MANAGED_SOURCE", "s2-managed")
	t.Setenv("METON_MANAGED_EPOCH", "1")
	var sample struct {
		Call, Foreign Call
		Keys          []SessionKey
	}
	raw, err := os.ReadFile(os.Getenv("METON_RESERVATION_FIXTURE"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &sample); err != nil || len(sample.Keys) != 2 {
		t.Fatal("invalid fixture")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	open := func(role string) *TextLedger {
		db, e := sql.Open("postgres", "host=127.0.0.1 port=5432 dbname=s2_grants sslmode=disable user="+role)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { db.Close() })
		l, e := NewTextLedger(db)
		if e != nil {
			t.Fatal(e)
		}
		return l
	}
	w, reader, closer, sender := open("s2_reserve"), open("s2_read"), open("s2_cancel"), open("s2_send")
	c := sample.Call
	q := Estimate{Protocol: "responses", Model: "meton-s2-text-fixture", Digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", DigestVersion: 1, InputBound: 2, OutputBound: 1}
	if h, e := reader.Find(ctx, c); h != nil || !errors.Is(e, sql.ErrNoRows) {
		t.Fatal("missing was accepted", e)
	}
	if h, e := reader.Reserve(ctx, c, sample.Keys[0], q); h != nil || e == nil {
		t.Fatal("read-only subject could reserve")
	}
	held, e := w.Reserve(ctx, c, sample.Keys[0], q)
	if e != nil {
		t.Fatal(e)
	}
	if held.State != "prepared" || held.Quote != "3.00000000" || held.AcceptedEpoch != 1 || held.PriceVersion != "v1" ||
		held.Unit != "sample-credit" || len(held.Allocations) != 1 || held.Allocations[0].Kind != "grant" || held.Allocations[0].Amount != held.Quote {
		t.Fatal("wrong original quote")
	}
	same, e := w.Reserve(ctx, c, sample.Keys[1], q)
	if e != nil || !reflect.DeepEqual(same, held) {
		t.Fatal("different replay", e)
	}
	found, e := reader.Find(ctx, c)
	if e != nil || !reflect.DeepEqual(found, held) {
		t.Fatal("different original read", e)
	}
	if h, e := reader.Find(ctx, sample.Foreign); h != nil || !errors.Is(e, sql.ErrNoRows) {
		t.Fatal("read foreign request", e)
	}
	changed := q
	changed.OutputBound++
	if h, e := w.Reserve(ctx, c, sample.Keys[1], changed); h != nil || e == nil {
		t.Fatal("accepted changed bounds")
	}
	id := held.Origin.SourceRequestID
	if ok, e := sender.ClaimDispatch(ctx, c, id, sample.Keys[1]); ok || e != nil {
		t.Fatal("replay could replace original device", e)
	}
	if ok, e := sender.ClaimDispatch(ctx, c, id, sample.Keys[0]); !ok || e != nil {
		t.Fatal("missing first claim", e)
	}
	if ok, e := sender.ClaimDispatch(ctx, c, id, sample.Keys[0]); ok || e != nil {
		t.Fatal("duplicate claim", e)
	}
	after, e := closer.CancelUnsent(ctx, c, id)
	if e != nil || after.State != "dispatch_claimed" || !reflect.DeepEqual(after.Allocations, held.Allocations) {
		t.Fatal("lost dispatched hold", e)
	}
	c.OperationID = uuid.NewString()
	q.InputBound = 3
	second, e := w.Reserve(ctx, c, sample.Keys[1], q)
	if e != nil || len(second.Allocations) != 2 || second.Allocations[0].Amount != "2.00000000" || second.Allocations[1].Kind != "purchase" {
		t.Fatal("incorrect mixed hold", e)
	}
	for i := 0; i < 2; i++ {
		closed, e := closer.CancelUnsent(ctx, c, second.Origin.SourceRequestID)
		if e != nil || closed.State != "cancelled_unsent" || !reflect.DeepEqual(closed.Allocations, second.Allocations) {
			t.Fatal("cancel changed original allocation", e)
		}
	}
	if ok, e := sender.ClaimDispatch(ctx, c, second.Origin.SourceRequestID, sample.Keys[1]); ok || e != nil {
		t.Fatal("cancelled was claimed", e)
	}
	c.OperationID = uuid.NewString()
	stopped, stop := context.WithCancel(ctx)
	stop()
	if h, e := w.Reserve(stopped, c, sample.Keys[0], q); h != nil || !errors.Is(e, context.Canceled) {
		t.Fatal("cancelled context created a hold", e)
	}
	if h, e := reader.Find(ctx, c); h != nil || !errors.Is(e, sql.ErrNoRows) {
		t.Fatal("unsubmitted call was persisted", e)
	}
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s1")
	if h, e := w.Reserve(ctx, c, sample.Keys[0], q); h != nil || e == nil {
		t.Fatal("old mode could reserve")
	}
	if _, e := NewTextLedger(w.db); e == nil {
		t.Fatal("old mode constructed a source writer")
	}
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s2-source-v1")
	t.Setenv("METON_MANAGED_EPOCH", "2")
	if ok, e := sender.ClaimDispatch(ctx, c, id, sample.Keys[0]); ok || e == nil {
		t.Fatal("old pool operated after epoch change")
	}
}
