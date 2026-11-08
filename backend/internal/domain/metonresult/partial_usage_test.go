//go:build meton_managed

package metonresult

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

/** TestPartialTextUsage 只用合成原响应检查新增分支。记录的正常及费用未知样本交给同批的来源数据库检查。 */
func TestPartialTextUsage(t *testing.T) {
	const source = "gpt-5.6-sol"
	const standard = `"input_tokens":2,"input_tokens_details":{"cached_tokens":1,"cache_write_tokens":0},"output_tokens":1,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":3`
	const opaque = `,"attribution":{"private-test-label":"private-test-value"}`
	frame := func(data string) string { return "data: " + data + "\n\n" }
	created := frame(`{"type":"response.created","response":{"id":"r","model":"` + source + `","status":"in_progress"}}`)
	end := func(usage string) string {
		return frame(`{"type":"response.completed","response":{"id":"r","model":"` + source + `","status":"completed","output":[{"type":"message","content":[{"type":"output_text"}]}],"usage":{` + usage + `}}}`)
	}
	original := created + end(standard+opaque)
	for _, tc := range []struct {
		name, body string
		bound, known, ready bool
	}{
		{"opaque_terminal", original, true, true, false},
		{"ordinary_terminal", created + end(standard), true, true, true},
		{"untied_endpoint", original, false, false, false},
		{"missing_creation", end(standard+opaque), true, false, false},
		{"wrong_response", strings.Replace(original, `"id":"r","model"`, `"id":"other","model"`, 1), true, false, false},
		{"total_conflicts", strings.Replace(original, `"total_tokens":3`, `"total_tokens":4`, 1), true, false, false},
		{"total_absent", strings.Replace(original, `,"total_tokens":3`, "", 1), true, false, false},
		{"cache_absent", strings.Replace(original, `"cached_tokens":1,`, "", 1), true, false, false},
		{"cache_excess", strings.Replace(original, `"cached_tokens":1`, `"cached_tokens":7`, 1), true, false, false},
		{"other_unit", created + end(standard+opaque+`,"additional_cost":0`), true, false, false},
		{"cache_write", strings.Replace(original, `"cache_write_tokens":0`, `"cache_write_tokens":1`, 1), true, false, false},
		{"tool_charge", strings.Replace(original, `"usage":`, `"tool_usage":{"web_search":{"num_requests":1}},"usage":`, 1), true, false, false},
		{"empty_extension", created + end(standard+`,"attribution":{}`), true, false, false},
		{"wrong_type", created + end(standard+`,"attribution":"private-test-value"`), true, false, false},
		{"duplicate_nested", created + end(standard+`,"attribution":{"a":1,"a":2}`), true, false, false},
		{"truncated", strings.TrimSuffix(original, "\n\n"), true, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := &http.Response{StatusCode: 200, Header: http.Header{"Content-Type":{"text/event-stream"}}, Body: io.NopCloser(strings.NewReader(tc.body))}
			var s Snapshot
			reader, err := NewSourceResponse(response, "responses", source, tc.bound, func(value Snapshot) { s = value })
			if err != nil { t.Fatal(err) }
			data, err := io.ReadAll(reader)
			digest := sha256.Sum256([]byte(tc.body))
			if err != nil || string(data) != tc.body || !s.Valid() || s.BodySHA256 != hex.EncodeToString(digest[:]) ||
				(s.Usage != nil) != tc.known || s.FeeReady != tc.ready {
				t.Fatal("实际交付字节、原计量或费用状态不符")
			}
			if !tc.known { return }
			if s.Execution != "completed" || s.Terminal != "response.completed" || s.Usage.Cached == nil || s.Usage.Input != 2 || *s.Usage.Cached != 1 || s.Usage.Output != 1 {
				t.Fatal("原响应的明确计量不符")
			}
			shape := reader.MeterDiagnostic()
			if tc.name == "opaque_terminal" && (!shape.Rejected["usage_attribution"] || shape.Usage["attribution."+meterName("private-test-label")] != "string") {
				t.Fatal("未在原诊断留下未定费用及脱敏字段形状")
			}
			diagnostic, _ := json.Marshal(shape)
			snapshot, _ := json.Marshal(s)
			if strings.Contains(string(diagnostic)+string(snapshot), "private-test-") { t.Fatal("扩展名称或值进入回执") }
			t.Logf("METON_PARTIAL_TEST_SNAPSHOT %s", snapshot)
		})
	}
}
