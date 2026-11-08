//go:build meton_managed && unit

package metonledger

import (
	"encoding/json"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
	"github.com/google/uuid"
)

/** 回执校验拒绝错归属、缺原费用及伪造零账单；不重算供应价格或写入资金。 */
func TestModelCompletionReceiptGuards(t *testing.T) {
	origin := metonfee.Origin{Environment: "fixture", Source: "fixture", User: uuid.NewString(), Account: uuid.NewString(), SourceMarker: uuid.NewString(), Caller: "meton.chat.v1", OperationID: uuid.NewString(), SourceRequestID: uuid.NewString()}
	event, credit, journal := uuid.NewString(), uuid.NewString(), uuid.NewString()
	zero := int64(0)
	observed := metonresult.Unavailable("responses")
	observed.Execution = "completed"
	observed.Terminal = "response.completed"
	observed.ResponseID = "resp_one"
	observed.ReadEnd = "eof"
	observed.FeeReady = true
	observed.Usage = &metonresult.Usage{Input: 1, Output: 1, Cached: &zero}
	r := ExecutionResult{Version: 1, Origin: origin, EventID: event, Observation: observed,
		Posting: &FeePosting{Report: FeeReport{Version: 1, Origin: origin, Item: metonfee.Item{ChargeItemID: origin.SourceRequestID, EventID: event, Revision: 1, State: "final", PriceVersion: "v1", Unit: "sample", Amount: "2.00000000"}},
			Funded: "2.00000000", Uncovered: "0.00000000", Change: "2.00000000", LedgerEvent: &journal, Sources: []SourceChange{{Ordinal: 1, CreditEvent: credit, Change: "2.00000000"}}},
		Ending: &FeeEnding{FeeManifest: FeeManifest{Proof: event, FinalEvents: []string{event}}, Request: origin.SourceRequestID, Released: []CoverPart{{Ordinal: 1, CreditEvent: credit, Amount: "1.00000000"}}}}
	if verifyExecution(r, origin) != nil {
		t.Fatal("valid original rejected")
	}
	raw, _ := json.Marshal(r)
	for name, mutate := range map[string]func(*ExecutionResult){
		"version":                func(x *ExecutionResult) { x.Version = 2 },
		"owner":                  func(x *ExecutionResult) { x.Origin.User = uuid.NewString() },
		"event":                  func(x *ExecutionResult) { x.EventID = uuid.NewString() },
		"missing_posting":        func(x *ExecutionResult) { x.Posting = nil },
		"missing_ending":         func(x *ExecutionResult) { x.Ending = nil },
		"revised_without_source": func(x *ExecutionResult) { x.Posting.Report.Item.Revision = 2 },
		"wrong_price_type":       func(x *ExecutionResult) { x.Posting.Report.Item.Unit = "" },
		"wrong_fee_owner":        func(x *ExecutionResult) { x.Posting.Report.Origin.Account = uuid.NewString() },
		"unbalanced":             func(x *ExecutionResult) { x.Posting.Funded = "3.00000000" },
		"split_missing":          func(x *ExecutionResult) { x.Posting.Sources = []SourceChange{} },
		"wrong_request":          func(x *ExecutionResult) { x.Ending.Request = uuid.NewString() },
		"wrong_proof":            func(x *ExecutionResult) { x.Ending.Proof = uuid.NewString() },
		"wrong_final":            func(x *ExecutionResult) { x.Ending.FinalEvents = []string{uuid.NewString()} },
		"duplicate_final":        func(x *ExecutionResult) { x.Ending.FinalEvents = append(x.Ending.FinalEvents, event) },
		"missing_releases":       func(x *ExecutionResult) { x.Ending.Released = nil },
		"negative_release":       func(x *ExecutionResult) { x.Ending.Released[0].Amount = "-1.00000000" },
		"duplicate_release":      func(x *ExecutionResult) { x.Ending.Released = append(x.Ending.Released, x.Ending.Released[0]) },
		"no_usage":               func(x *ExecutionResult) { x.Observation.Usage = nil },
		"no_cache":               func(x *ExecutionResult) { x.Observation.Usage.Cached = nil },
		"missing_terminal":       func(x *ExecutionResult) { x.Observation.Terminal = "" },
		"unknown_with_posting":   func(x *ExecutionResult) { x.Observation = metonresult.Unavailable("responses") },
	} {
		t.Run(name, func(t *testing.T) {
			var changed ExecutionResult
			_ = json.Unmarshal(raw, &changed)
			mutate(&changed)
			if verifyExecution(changed, origin) == nil {
				t.Fatal("invalid original accepted")
			}
		})
	}
	r.Observation = metonresult.Unavailable("responses")
	r.Posting = nil
	r.Ending = nil
	if verifyExecution(r, origin) != nil {
		t.Fatal("unknown original rejected")
	}
}
