//go:build meton_managed

package metonresult

import (
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

/** TestAcceptedTokenPrice 只覆盖新受理费率与旧原单的分界。工具、计量和终局仍使用原观察器。 */
func TestAcceptedTokenPrice(t *testing.T) {
	const model = "gpt-5.6-sol"
	const opaque = `{"supplier-only":"value"}`
	const standard = `"input_tokens":8,"input_tokens_details":{"cached_tokens":3,"cache_write_tokens":0},"output_tokens":2,"total_tokens":10`
	const created = "data: " + `{"type":"response.created","response":{"id":"r","model":"gpt-5.6-sol","status":"in_progress"}}` + "\n\n"
	const end = "data: " + `{"type":"response.completed","response":{"id":"r","model":"gpt-5.6-sol","status":"completed","output":[{"type":"function_call"}],"usage":{` + standard + `,"attribution":` + opaque + `}}}` + "\n\n"
	accepted := AcceptedTextPrice{"s1-isolated", "s1-managed", model, "sample-credit", "s2-60885-text-v2"}
	old, foreign, otherModel := accepted, accepted, accepted
	old.Version = "s2-60885-text-v1"
	foreign.Source = "other"
	otherModel.Model = "other"
	for _, tc := range []struct {
		name string
		price AcceptedTextPrice
		body string
		bound, fee, fingerprint bool
	}{
		{"new_original", accepted, created+end, true, true, true},
		{"old_price", old, created+end, true, false, false},
		{"foreign_source", foreign, created+end, true, false, false},
		{"other_model", otherModel, created+end, true, false, false},
		{"ordinary_route", accepted, created+end, false, false, false},
		{"missing_start", accepted, end, true, false, false},
		{"other_meter", accepted, strings.Replace(created+end, standard, standard+`,"unknown_unit":1`, 1), true, false, false},
		{"tool_charge", accepted, strings.Replace(created+end, `"output":[`, `"tool_usage":{"web_search":{"num_requests":1}},"output":[`, 1), true, false, false},
		{"different_total", accepted, strings.Replace(created+end, `"total_tokens":10`, `"total_tokens":11`, 1), true, false, false},
		{"malformed", accepted, strings.Replace(created+end, opaque, `null`, 1), true, false, false},
		{"ordinary_usage", accepted, strings.Replace(created+end, `,"attribution":`+opaque, "", 1), true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := &http.Response{StatusCode:200, Header:http.Header{"Content-Type":{"text/event-stream"}}, Body:io.NopCloser(strings.NewReader(tc.body))}
			var fact Snapshot
			r, err := NewPricedSourceResponse(resp, "responses", model, tc.bound, tc.price, func(s Snapshot) {fact = s})
			if err != nil { t.Fatal(err) }
			raw, err := io.ReadAll(r)
			if err != nil || string(raw) != tc.body || !fact.Valid() || fact.FeeReady != tc.fee {
				t.Fatal("用户费率、原观察或交付字节不符")
			}
			want := ""
			if tc.fingerprint { want = fmt.Sprintf("%x", sha256.Sum256([]byte(opaque))) }
			if r.SupplierAttributionDigest() != want { t.Fatal("供应归属摘要不符") }
			if tc.fee && (fact.Usage == nil || fact.Usage.Cached == nil || fact.Usage.Input != 8 || *fact.Usage.Cached != 3 || fact.Usage.Output != 2) {
				t.Fatal("三项用户计量不符")
			}
		})
	}
}
