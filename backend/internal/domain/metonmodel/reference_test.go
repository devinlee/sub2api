package metonmodel

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

func TestMetonModelReadSpecification(t *testing.T) {
	id := "10000000-0000-4000-8000-000000000001"
	zero := 0
	a := Admission{1, metonfee.Origin{"s2-isolated", "s2-managed", id, id, id, "meton.chat.v1", id, id}, 1,
		Request{"responses", "org/model:v1", 1, strings.Repeat("a", 64), &zero, 1}, Pricing{"v1", "unit", "1.00000000"}}
	wire, _ := json.Marshal(a)
	if got, err := ReadAdmission(wire); err != nil || got.Request.InputBound == nil || *got.Request.InputBound != 0 {
		t.Fatal("valid zero input or model rejected", err)
	}
	for _, bad := range []string{strings.Replace(string(wire), "\"input_bound\":0,", "", 1), strings.Replace(string(wire), "\"input_bound\":0", "\"input_bound\":-1", 1),
		strings.Replace(string(wire), "\"quote\":\"1.00000000\"", "\"quote\":\"0.00000000\"", 1), strings.Replace(string(wire), "\"accepted_epoch\":1", "\"accepted_epoch\":0", 1), string(wire) + "{}"} {
		if _, err := ReadAdmission([]byte(bad)); err == nil {
			t.Fatal("invalid source specification accepted")
		}
	}
}
