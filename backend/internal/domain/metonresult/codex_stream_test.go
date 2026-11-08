//go:build meton_managed

package metonresult

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

/** TestBoundCodexStream 用真实联验观察到的事件次序和计量形状验证读取，不把桌面样本当成资金证据。 */
func TestBoundCodexStream(t *testing.T) {
	const created = "data: {\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"model\":\"m\",\"status\":\"in_progress\"}}\n\n"
	const meta = "data: {\"type\":\"response.metadata\",\"response_id\":\"r\",\"metadata\":{\"openai_chatgpt_moderation_metadata\":{\"prompt\":{}}}}\n\n"
	const completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\"}]}],\"usage\":{\"input_tokens\":4402,\"output_tokens\":5,\"input_tokens_details\":{\"cached_tokens\":4224}}}}\n\n"
	full := created + meta + completed
	for _, tc := range []struct {
		name, body   string
		headers      http.Header
		codex, ready bool
	}{
		{"missing", full, http.Header{}, true, true},
		{"generic", full, http.Header{"Content-Type": {"application/octet-stream"}}, true, true},
		{"lower_case", full, http.Header{"content-type": {"text/event-stream; charset=UTF-8"}}, true, true},
		{"parameters", full, http.Header{"Content-Type": {"text/event-stream; version=1"}}, true, true},
		{"ordinary_strict", full, http.Header{}, false, false},
		{"html", full, http.Header{"Content-Type": {"text/html"}}, true, false},
		{"conflicting_headers", full, http.Header{"content-type": {"text/event-stream"}, "Content-Type": {"application/json"}}, true, false},
		{"encoded", full, http.Header{"Content-Encoding": {"gzip"}}, true, false},
		{"no_creation", completed, http.Header{}, true, false},
		{"truncated", strings.TrimSuffix(full, "\n"), http.Header{}, true, false},
		{"foreign_terminal", created + strings.ReplaceAll(completed, `"id":"r"`, `"id":"other"`), http.Header{}, true, false},
		{"foreign_metadata", created + strings.ReplaceAll(meta, `"response_id":"r"`, `"response_id":"other"`) + completed, http.Header{}, true, false},
		{"extra_cost", created + strings.ReplaceAll(meta, `"openai_chatgpt_moderation_metadata"`, `"cost"`) + completed, http.Header{}, true, false},
		{"missing_cached", created + strings.ReplaceAll(completed, `"cached_tokens":4224`, `"other":0`), http.Header{}, true, false},
		{"incorrect_model", created + strings.ReplaceAll(completed, `"model":"m"`, `"model":"n"`), http.Header{}, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var observed Snapshot
			resp := &http.Response{StatusCode: 200, Header: tc.headers, Body: io.NopCloser(strings.NewReader(tc.body))}
			reader, err := NewSourceResponse(resp, "responses", "m", tc.codex, func(s Snapshot) { observed = s })
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(reader)
			if err != nil || string(data) != tc.body || !observed.Valid() || observed.FeeReady != tc.ready {
				t.Fatalf("观察结果与原字节不符，execution=%q ready=%v reason=%s", observed.Execution, observed.FeeReady, reader.IncompleteReason(observed))
			}
			if tc.ready && (observed.ResponseID != "r" || observed.Execution != "completed" || observed.Terminal != "response.completed" ||
				observed.Usage.Input != 4402 || observed.Usage.Output != 5 || *observed.Usage.Cached != 4224) {
				t.Fatal("原终局和计量不符")
			}
		})
	}
	req, _ := http.NewRequest("POST", "https://chatgpt.com/backend-api/codex/responses", nil)
	if !CodexStreamRequest(req, []byte(`{"stream":true}`)) || CodexStreamRequest(req, []byte(`{"stream":false}`)) {
		t.Fatal("流式请求限定错误")
	}
	req.URL.Host = "other.invalid"
	if CodexStreamRequest(req, []byte(`{"stream":true}`)) {
		t.Fatal("其他目标取得 OAuth 兼容读取")
	}
}
