package metonmodel

import (
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"strings"
	"testing"
)

func resultFixture() Result {
	id := "10000000-0000-4000-8000-000000000001"
	event := "10000000-0000-4000-8000-000000000002"
	zero := 0
	cached := int64(0)
	a := Admission{1, metonfee.Origin{"s2-isolated", "s2-managed", id, id, id, "meton.chat.v1", id, id}, 1,
		Request{"responses", "org/model:v1", 1, strings.Repeat("a", 64), &zero, 1}, Pricing{"v1", "unit", "3.00000000"}}
	f := Fee{1, a.Origin, metonfee.Item{id, event, 1, "final", "v1", "unit", "3.00000000", nil}}
	return Result{1, a, &Completion{event, "completed", &ResultUsage{2, 1, &cached}, &ResultFee{f, "3.00000000", "0.00000000"}}}
}

/** 已知执行不等于已知费用；未知、已知零和不足部分不可合并成同一状态。 */
func TestMetonModelResult(t *testing.T) {
	for _, name := range []string{"paid", "unobserved", "unknown", "completed-unpriced", "zero", "failed-priced", "gap"} {
		t.Run(name, func(t *testing.T) {
			r := resultFixture()
			switch name {
			case "unobserved":
				r.Result = nil
			case "unknown":
				r.Result.Execution = "unknown"
				r.Result.Usage = nil
				r.Result.Fee = nil
			case "completed-unpriced":
				r.Result.Usage.Cached = nil
				r.Result.Fee = nil
			case "zero":
				r.Result.Usage.Input = 0
				r.Result.Usage.Output = 0
				r.Result.Fee.Reference.Item.Amount = "0.00000000"
				r.Result.Fee.Funded = "0.00000000"
			case "failed-priced":
				r.Result.Execution = "failed"
			case "gap":
				r.Result.Fee.Funded = "1.00000000"
				r.Result.Fee.Uncovered = "2.00000000"
			}
			wire, _ := json.Marshal(r)
			if _, err := ReadResult(wire); err != nil {
				t.Fatal("valid result rejected", err)
			}
		})
	}
	for name, mutate := range map[string]func(*Result){
		"owner":          func(r *Result) { r.Result.Fee.Reference.Origin.Account = "10000000-0000-4000-8000-000000000003" },
		"event":          func(r *Result) { r.Result.ObservationID = r.Admission.Origin.SourceRequestID },
		"request":        func(r *Result) { r.Result.Fee.Reference.Item.ChargeItemID = r.Result.ObservationID },
		"revision":       func(r *Result) { r.Result.Fee.Reference.Item.Revision = 2 },
		"unfinal":        func(r *Result) { r.Result.Fee.Reference.Item.State = "observed" },
		"wrong-price":    func(r *Result) { r.Result.Fee.Reference.Item.PriceVersion = "v2" },
		"wrong-unit":     func(r *Result) { r.Result.Fee.Reference.Item.Unit = "other" },
		"unbalanced":     func(r *Result) { r.Result.Fee.Uncovered = "1.00000000" },
		"negative":       func(r *Result) { r.Result.Fee.Funded = "-3.00000000" },
		"missing-cache":  func(r *Result) { r.Result.Usage.Cached = nil },
		"missing-usage":  func(r *Result) { r.Result.Usage = nil },
		"unknown-priced": func(r *Result) { r.Result.Execution = "unknown" },
		"over-cache":     func(r *Result) { *r.Result.Usage.Cached = 3 },
		"bad-tokens":     func(r *Result) { r.Result.Usage.Output = 100000001 },
		"bad-execution":  func(r *Result) { r.Result.Execution = "sent" },
	} {
		t.Run(name, func(t *testing.T) {
			r := resultFixture()
			mutate(&r)
			wire, _ := json.Marshal(r)
			if _, err := ReadResult(wire); err == nil {
				t.Fatal("invalid result accepted")
			}
		})
	}
	raw, _ := json.Marshal(resultFixture())
	wire := string(raw)
	for name, bad := range map[string]string{
		"duplicate":    strings.Replace(wire, "\"version\":1", "\"version\":1,\"version\":1", 1),
		"case-alias":   strings.Replace(wire, "\"execution\"", "\"Execution\"", 1),
		"missing-zero": strings.Replace(wire, "\"cached\":0", "\"unused\":0", 1),
		"missing-null": strings.Replace(wire, ",\"previous_event_id\":null", "", 1),
		"extra":        strings.Replace(wire, "\"execution\":", "\"may_dispatch\":true,\"execution\":", 1),
		"second-root":  wire + "{}", "utf8": wire[:10] + string([]byte{255}) + wire[10:],
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ReadResult([]byte(bad)); err == nil {
				t.Fatal("ambiguous result accepted")
			}
		})
	}
}
