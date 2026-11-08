//go:build meton_managed

package metonresult

import (
	_ "embed"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

//go:embed testdata/recorded_zero_tools.json
var recordedMeters []byte

/** TestRecordedTextMeters 从固定录制抽取原计量和输出类型，重组的事件不含正文和用户身份。 */
func TestRecordedTextMeters(t *testing.T) {
	var samples []struct {
		Name, Model  string
		Usage, Tools json.RawMessage
		Output       []string
		Ready        bool
	}
	if err := json.Unmarshal(recordedMeters, &samples); err != nil || len(samples) != 6 {
		t.Fatal("录制计量样本无效")
	}
	check := func(t *testing.T, model string, usage, tools []byte, kinds []string, codex, ready bool) {
		t.Helper()
		var output []map[string]any
		for _, kind := range kinds {
			item := map[string]any{"type": kind}
			if kind == "message" {
				item["content"] = []map[string]string{{"type": "output_text"}}
			}
			output = append(output, item)
		}
		items, _ := json.Marshal(output)
		body := "data: " + `{"type":"response.created","response":{"id":"r","model":"` + model + `","status":"in_progress"}}` + "\n\n" +
			"data: " + `{"type":"response.completed","response":{"id":"r","model":"` + model + `","status":"completed","output":` + string(items) + `,"usage":` + string(usage) + `,"tool_usage":` + string(tools) + `}}` + "\n\n"
		response := &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/event-stream"}}, Body: io.NopCloser(strings.NewReader(body))}
		var s Snapshot
		reader, err := NewSourceResponse(response, "responses", model, codex, func(result Snapshot) { s = result })
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(reader)
		if err != nil || string(b) != body || !s.Valid() || s.FeeReady != ready {
			t.Fatalf("费用判断或原字节不符，期望 %v，实际 %v", ready, s.FeeReady)
		}
		if ready {
			u := obj(usage)
			in, a := integer(u["input_tokens"])
			out, b := integer(u["output_tokens"])
			cached, c := integer(obj(u["input_tokens_details"])["cached_tokens"])
			if !a || !b || !c || s.Terminal != "response.completed" || s.Usage == nil || s.Usage.Cached == nil || s.Usage.Input != in || s.Usage.Output != out || *s.Usage.Cached != cached {
				t.Fatal("原模型成功终局或原计量不符")
			}
		}
	}
	for _, s := range samples {
		t.Run(s.Name, func(t *testing.T) { check(t, s.Model, s.Usage, s.Tools, s.Output, true, s.Ready) })
	}
	example := samples[0]
	for _, tc := range []struct{ name, field, from, to string }{
		{"cache_write_charged", "usage", `"cache_write_tokens":0`, `"cache_write_tokens":1`},
		{"cache_write_null", "usage", `"cache_write_tokens":0`, `"cache_write_tokens":null`},
		{"missing_cache", "usage", `"cached_tokens":`, `"other_cached":`},
		{"unknown_token_unit", "usage", `"cache_write_tokens":0`, `"cache_write_tokens":0,"new_unit":0`},
		{"paid_search", "tools", `"num_requests":0`, `"num_requests":1`},
		{"search_unknown", "tools", `"num_requests":0`, `"num_requests":null`},
		{"missing_image_count", "tools", `"image_tokens":0,`, ``},
		{"positive_image_detail", "tools", `"image_tokens":0`, `"image_tokens":1`},
		{"string_zero", "tools", `"total_tokens":0`, `"total_tokens":"0"`},
		{"unknown_tool", "tools", `"web_search":`, `"other_tool":`},
		{"duplicate_count", "tools", `"num_requests":0`, `"num_requests":1,"num_requests":0`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			u, tools := string(example.Usage), string(example.Tools)
			target := &tools
			if tc.field == "usage" {
				target = &u
			}
			if !strings.Contains(*target, tc.from) {
				t.Fatal("合成变体未作用于原字段")
			}
			*target = strings.Replace(*target, tc.from, tc.to, 1)
			check(t, example.Model, []byte(u), []byte(tools), example.Output, true, false)
		})
	}
	t.Run("other_route", func(t *testing.T) {
		check(t, example.Model, example.Usage, example.Tools, example.Output, false, false)
	})
	t.Run("media_output_even_if_zero", func(t *testing.T) {
		check(t, example.Model, example.Usage, example.Tools, []string{"image_generation_call"}, true, false)
	})
}
