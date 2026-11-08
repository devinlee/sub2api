//go:build meton_managed && settlement_integration

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

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

// TestTextFeesPostgres 用真实来源库重放同一事件，核对累计、终局、修订和差额在 Go 边界仍能区分。
func TestTextFeesPostgres(t *testing.T) {
	var sample struct{ A, B metonfee.Origin }
	raw, err := os.ReadFile(os.Getenv("METON_SETTLEMENT_FIXTURE"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &sample); err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]string{"METON_MANAGED_ENVIRONMENT": "s2-isolated", "METON_MANAGED_SOURCE": "s2-managed", "METON_MANAGED_EPOCH": "1", "METON_MANAGED_FUNDS_MODE": "s2-source-v1"} {
		t.Setenv(k, v)
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
	observe, post, finish, dual, cover, read := open("s2_progress"), open("s2_settle"), open("s2_finish"), open("s2_dual"), open("s2_cover"), open("s2_read")
	item := func(amount, state string) metonfee.Item {
		return metonfee.Item{ChargeItemID: uuid.NewString(), EventID: uuid.NewString(), Revision: 1, State: state, PriceVersion: "v1", Unit: "sample-credit", Amount: amount}
	}
	x := item("2.00000000", "observed")
	if r, e := observe.ObserveFee(ctx, sample.A, x); e != nil || r.Item.Amount != x.Amount {
		t.Fatal("observe", e)
	}
	y := x
	y.EventID = uuid.NewString()
	y.Revision = 2
	y.Amount = "3.00000000"
	if _, e := observe.ObserveFee(ctx, sample.A, y); e != nil {
		t.Fatal(e)
	}
	if r, e := read.FindFee(ctx, sample.A, x.ChargeItemID, x.EventID); e != nil || r.Item != x {
		t.Fatal("find first observation", e)
	}
	if p, e := read.FindPosting(ctx, sample.A, x.ChargeItemID, x.EventID); p != nil || !errors.Is(e, sql.ErrNoRows) {
		t.Fatal("observation became posting", e)
	}
	final := x
	final.EventID = uuid.NewString()
	final.Revision = 3
	final.State = "final"
	if p, e := read.PostFee(ctx, sample.A, final, nil); p != nil || e == nil {
		t.Fatal("read role could post")
	}
	p, e := post.PostFee(ctx, sample.A, final, nil)
	if e != nil || p.Funded != "2.00000000" || p.Uncovered != "0.00000000" || p.LedgerEvent == nil || len(p.Sources) != 1 {
		t.Fatal("first fee", e)
	}
	again, e := read.FindPosting(ctx, sample.A, final.ChargeItemID, final.EventID)
	if e != nil || !reflect.DeepEqual(again, p) {
		t.Fatal("find original posting", e)
	}
	if end, e := read.FindEnding(ctx, sample.A); end != nil || !errors.Is(e, sql.ErrNoRows) {
		t.Fatal("partial fee closed request", e)
	}
	second := item("1.00000000", "final")
	manifest := FeeManifest{uuid.NewString(), []string{second.EventID, final.EventID}}
	if p, e := post.PostFee(ctx, sample.A, second, &manifest); p != nil || e == nil {
		t.Fatal("missing terminal authority")
	}
	if p, e := read.FindPosting(ctx, sample.A, second.ChargeItemID, second.EventID); p != nil || !errors.Is(e, sql.ErrNoRows) {
		t.Fatal("failed atomic ending committed money")
	}
	paid, e := dual.PostFee(ctx, sample.A, second, &manifest)
	if e != nil || paid.Funded != "1.00000000" {
		t.Fatal("atomic ending", e)
	}
	replay, e := dual.PostFee(ctx, sample.A, second, &manifest)
	if e != nil || !reflect.DeepEqual(paid, replay) {
		t.Fatal("duplicate final", e)
	}
	end, e := finish.EndFees(ctx, sample.A, manifest)
	if e != nil || len(end.Released) != 1 || end.Released[0].Amount != "2.00000000" {
		t.Fatal("wrong tail release", e)
	}
	same, e := read.FindEnding(ctx, sample.A)
	if e != nil || !reflect.DeepEqual(end, same) {
		t.Fatal("find ending", e)
	}
	amend := second
	amend.PreviousEventID = &second.EventID
	amend.EventID = uuid.NewString()
	amend.Revision = 2
	amend.State = "revised"
	amend.Amount = "2.00000000"
	if r, e := post.PostFee(ctx, sample.A, amend, nil); e != nil || r.Change != "1.00000000" || r.Funded != amend.Amount {
		t.Fatal("increase", e)
	}
	down := amend
	down.PreviousEventID = &amend.EventID
	down.EventID = uuid.NewString()
	down.Revision++
	down.Amount = "0.50000000"
	if r, e := post.PostFee(ctx, sample.A, down, nil); e != nil || r.Change != "-1.50000000" || r.Funded != down.Amount {
		t.Fatal("decrease", e)
	}
	proof := uuid.NewString()
	covered, e := cover.AddCover(ctx, sample.B, proof, "v1", "sample-credit", "2.00000000")
	if e != nil || !covered.Covered || len(covered.Sources) != 1 {
		t.Fatal("additional cover", e)
	}
	back, e := read.FindCover(ctx, sample.B, proof)
	if e != nil || !reflect.DeepEqual(covered, back) {
		t.Fatal("find cover", e)
	}
	over := item("9.00000000", "final")
	overEnd := FeeManifest{uuid.NewString(), []string{over.EventID}}
	short, e := dual.PostFee(ctx, sample.B, over, &overEnd)
	if e != nil || short.Funded != "7.00000000" || short.Uncovered != "2.00000000" || short.Change != "7.00000000" {
		t.Fatal("actual shortfall", e)
	}
	if r, e := read.FindPosting(ctx, sample.A, over.ChargeItemID, over.EventID); r != nil || !errors.Is(e, sql.ErrNoRows) {
		t.Fatal("foreign receipt", e)
	}
}
