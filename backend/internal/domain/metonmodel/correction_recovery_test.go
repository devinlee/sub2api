package metonmodel

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

/** 当前控制代次与原受理分别保留；形状解析不代替服务身份、历史清单或来源恢复链复验。 */
func TestRestoredCorrectionRequestKeepsOriginalAdmission(t *testing.T) {
	id := "10000000-0000-4000-8000-000000000001"
	zero := 0
	a := Admission{1, metonfee.Origin{"s2-isolated", "s2-managed", id, id, id, "meton.chat.v1", id, id}, 1,
		Request{"responses", "org/model:v1", 1, strings.Repeat("a", 64), &zero, 1}, Pricing{"v1", "unit", "1.00000000"}}
	previous := strings.Repeat("b", 64)
	q := CorrectionRequest{Version: 1, Epoch: 5, UntilMS: 1000, Admission: a, Item: id, Basis: id,
		Selection: &CorrectionSelection{Decision: id, CaseID: id, AttemptID: id, RulingVersion: 1, Generation: 2, ApprovalDigest: strings.Repeat("c", 64)},
		Review: &CorrectionReview{PreviousDigest: &previous, ValidUntilMS: 2000, Sources: []CorrectionLine{{CreditEvent: id, Amount: "1.00000000"}}}}
	for _, action := range []string{"approve", "apply", "resolution"} {
		input := q
		if action != "approve" {
			input.Review = nil
		}
		wire, _ := json.Marshal(input)
		got, err := ReadCorrection(action, wire)
		if err != nil || got.Epoch != 5 || got.Admission.AcceptedEpoch != 1 || got.Selection.Generation != 2 || !reflect.DeepEqual(got.Admission, a) {
			t.Fatal("historical admission or current approval identity changed", action, err)
		}
	}
	for _, change := range []func(*CorrectionRequest){
		func(v *CorrectionRequest) { v.Epoch = 0 },
		func(v *CorrectionRequest) { v.Admission.AcceptedEpoch = 6 },
		func(v *CorrectionRequest) { v.Review.PreviousDigest = nil },
	} {
		input := q
		review := *q.Review
		input.Review = &review
		change(&input)
		wire, _ := json.Marshal(input)
		if _, err := ReadCorrection("approve", wire); err == nil {
			t.Fatal("invalid recovery or approval predecessor accepted")
		}
	}
}
