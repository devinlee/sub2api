package metonfee

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

func ref(n int) string { return fmt.Sprintf("10000000-0000-4000-8000-%012d", n) }

func TestFeeWire(t *testing.T) {
	origin := Origin{"s2-isolated", "s2-managed", ref(1), ref(2), ref(3), "meton.chat.v1", ref(4), ref(5)}
	item := Item{ref(6), ref(7), 1, "observed", "fixture-v1", "sample-credit", "2.00000000", nil}
	var encoded []json.RawMessage
	add := func() {
		t.Helper()
		b, err := Encode(origin, item)
		if err != nil {
			t.Fatal(err)
		}
		encoded = append(encoded, b)
	}
	add()
	item.Amount, item.Revision, item.EventID = "3.00000000", 2, ref(8)
	add()
	item.State, item.Revision, item.EventID = "final", 3, ref(9)
	add()
	add()
	final := item
	item.ChargeItemID, item.Amount, item.Revision, item.EventID = ref(10), "2.00000000", 1, ref(11)
	add()
	item = final
	item.State, item.Revision, item.EventID, item.Amount, item.PreviousEventID = "revised", 4, ref(12), "2.50000000", &final.EventID
	add()
	origin.Caller, origin.OperationID, origin.SourceRequestID = "meton.oc07.v1", ref(13), ref(14)
	item.ChargeItemID, item.EventID, item.State, item.Revision, item.PreviousEventID = ref(15), ref(16), "final", 1, nil
	for i, amount := range []string{"999999999999.99999999", "0.00000001", "0.00000000"} {
		item.Amount, item.ChargeItemID, item.EventID = amount, ref(15+i*2), ref(16+i*2)
		add()
	}
	for _, amount := range []string{"", "3", "03.00000000", "0.000000001", "-2.00000000", "1000000000000.00000000", "NaN", "1e-8"} {
		item.Amount = amount
		if _, err := Encode(origin, item); err == nil {
			t.Errorf("accepted invalid amount %q", amount)
		}
	}
	item.Amount, item.State = "1.00000000", "revised"
	if _, err := Encode(origin, item); err == nil {
		t.Fatal("accepted unlinked correction")
	}
	if path := os.Getenv("METON_FEE_EXPORT"); path != "" {
		b, err := json.Marshal(encoded)
		if err == nil {
			err = os.WriteFile(path, b, 0600)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}
