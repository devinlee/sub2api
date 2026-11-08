//go:build meton_managed

package metonresult

import (
	"io"
	"strings"
	"testing"
)

/** TestReadIssueKeepsOriginalObservation 只验证新增原因，不从未知状态推断费用。 */
func TestReadIssueKeepsOriginalObservation(t *testing.T) {
	const created = "data: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\",\"model\":\"m\"}}\n\n"
	const completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"model\":\"m\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":3,\"output_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0}}}}\n\n"
	for _, tc := range []struct {
		name, body, media, reason string
		ready                     bool
	}{
		{"original_terminal", created + completed, "text/event-stream", "none", true},
		{"alias", strings.ReplaceAll(created, `"m"`, `"different"`), "text/event-stream", "response_model_mismatch", false},
		{"partial_event", created + "data: {", "text/event-stream", "partial_sse_event", false},
		{"missing_terminal", created, "text/event-stream", "missing_terminal", false},
		{"foreign_event", "data: {\"type\":\"private-value\"}\n\n", "text/event-stream", "foreign_event", false},
		{"mime", created, "application/octet-stream", "media_type", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var original Snapshot
			observer, err := New(io.NopCloser(strings.NewReader(tc.body)), "responses", "m", tc.media, 200, func(s Snapshot) { original = s })
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(observer)
			if err != nil || string(data) != tc.body || original.FeeReady != tc.ready || observer.IncompleteReason(original) != tc.reason {
				t.Fatalf("观察、字节或原因不符，ready=%v reason=%s", original.FeeReady, observer.IncompleteReason(original))
			}
			if !tc.ready && (original.Usage != nil || original.Terminal != "") {
				t.Fatal("诊断增加了结算事实")
			}
		})
	}
	if EncodingClass("raw-private-value") != "other" || EncodingClass(" GZip ") != "gzip" {
		t.Fatal("编码分类越界")
	}
}
