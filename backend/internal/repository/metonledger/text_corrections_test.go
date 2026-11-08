//go:build meton_managed && correction_integration

package metonledger

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/google/uuid"
)

// TestTextCorrectionPostgres 从原费用经批准、执行、查询及迟到证据走真实来源库。
func TestTextCorrectionPostgres(t *testing.T) {
	var sample struct {
		Origin, Foreign metonfee.Origin
		Original        metonfee.Item
		Gift, Purchase  string
	}
	raw, err := os.ReadFile(os.Getenv("METON_CORRECTION_FIXTURE"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &sample); err != nil {
		t.Fatal(err)
	}
	open := func(role string) *TextLedger {
		db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { db.Close() })
		l, err := NewTextLedger(db)
		if err != nil {
			t.Fatal(err)
		}
		return l
	}
	ctx := context.Background()
	ruler, writer, reader, late, fees := open("s2_rule"), open("s2_correct"), open("s2_read"), open("s2_late"), open("s2_settle")
	k := CorrectionKey{sample.Original.ChargeItemID, sample.Original.EventID, uuid.NewString()}
	ruling := CorrectionRuling{k, 1, true, []CorrectionSource{{sample.Purchase, "1.25000000"}, {sample.Gift, "2.00000000"}}}
	if _, err := writer.ApplyCorrection(ctx, sample.Origin, k, 1); err == nil {
		t.Fatal("unapproved correction")
	}
	a, err := ruler.ApproveCorrection(ctx, sample.Origin, ruling)
	if err != nil || a.Amount != "3.25000000" {
		t.Fatal("approval", err)
	}
	b, err := reader.FindDecision(ctx, sample.Origin, k)
	if err != nil || !reflect.DeepEqual(a, b) {
		t.Fatal("read approval", err)
	}
	if _, err := ruler.ApplyCorrection(ctx, sample.Origin, k, 1); err == nil {
		t.Fatal("approval acquired execution")
	}
	if _, err := reader.FindCorrection(ctx, sample.Origin, k); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("approval became funds", err)
	}
	x, err := writer.ApplyCorrection(ctx, sample.Origin, k, 1)
	if err != nil || !reflect.DeepEqual(x.Approval, *a) {
		t.Fatal("apply", err)
	}
	again, err := writer.ApplyCorrection(ctx, sample.Origin, k, 1)
	if err != nil || !reflect.DeepEqual(again, x) {
		t.Fatal("duplicate execution", err)
	}
	found, err := reader.FindCorrection(ctx, sample.Origin, k)
	if err != nil || !reflect.DeepEqual(found, x) {
		t.Fatal("read correction", err)
	}
	if _, err := reader.FindCorrection(ctx, sample.Foreign, k); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("foreign correction", err)
	}
	original, err := fees.PostFee(ctx, sample.Origin, sample.Original, nil)
	if err != nil || original.Funded != "8.00000000" {
		t.Fatal("old confirmed fee", err)
	}
	changed := sample.Original
	changed.EventID = uuid.NewString()
	changed.PreviousEventID = &sample.Original.EventID
	changed.Revision++
	changed.State = "revised"
	changed.Amount = "9.00000000"
	posting, err := fees.PostFee(ctx, sample.Origin, changed, nil)
	var dispute *FeeReviewRequired
	if posting != nil || !errors.As(err, &dispute) || dispute.Dispute.Decision != k.Decision {
		t.Fatal("late fee not routed to review", err)
	}
	rows, err := reader.FindDisputes(ctx, sample.Origin, k.Item, changed.EventID)
	if err != nil || len(rows) != 1 || !reflect.DeepEqual(rows[0], dispute.Dispute) {
		t.Fatal("read lost late fee", err)
	}
	if _, err := reader.FindPosting(ctx, sample.Origin, k.Item, changed.EventID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("conflict acquired financial receipt", err)
	}
	event, proof := uuid.NewString(), uuid.NewString()
	out, err := late.NoteLateSuccess(ctx, sample.Origin, k.Item, event, proof)
	if err != nil || out.Decision != k.Decision {
		t.Fatal("late execution", err)
	}
	againLate, err := late.NoteLateSuccess(ctx, sample.Origin, k.Item, event, proof)
	if err != nil || !reflect.DeepEqual(out, againLate) {
		t.Fatal("duplicate execution notice", err)
	}
}
