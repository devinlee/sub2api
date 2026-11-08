//go:build meton_managed

package metonresult

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

/** TestMeterShapeOnlyObserves 用合成回包验证脱敏定位、原字节与原费用状态，样本不签收任何真实费用。 */
func TestMeterShapeOnlyObserves(t *testing.T) {
	const created = `{"type":"response.created","response":{"id":"r","model":"m","status":"in_progress"}}`
	const good = `"input_tokens":4402,"output_tokens":5,"input_tokens_details":{"cached_tokens":4224},"total_tokens":4407`
	const sensitive = "PRIVATE_SAMPLE_DO_NOT_LOG"
	const meta = `{"type":"response.metadata","response_id":"r","metadata":{"openai_chatgpt_moderation_metadata":{"prompt":"` + sensitive + `"},"` + sensitive + `":"` + sensitive + `"}}`
	observe := func(t *testing.T, usage, extra, prior string, codex bool) (Snapshot, *Reader) {
		t.Helper()
		wire := "data: " + created + "\n\n"
		if prior != "" {
			wire += "data: " + prior + "\n\n"
		}
		wire += "data: " + `{"type":"response.completed","response":{"id":"r","model":"m","status":"completed","output":[],"usage":{` + usage + `}` + extra + `}}` + "\n\n"
		var snapshot Snapshot
		response := &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"text/event-stream"}}, Body: io.NopCloser(strings.NewReader(wire))}
		r, err := NewSourceResponse(response, "responses", "m", codex, func(s Snapshot) { snapshot = s })
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(r)
		sum := sha256.Sum256([]byte(wire))
		if err != nil || string(body) != wire || !snapshot.Valid() || snapshot.BodySHA256 != hex.EncodeToString(sum[:]) || snapshot.ResponseID != "r" || snapshot.Terminal != "response.completed" {
			t.Fatal("取证改变了原回包或原观察")
		}
		return snapshot, r
	}
	t.Run("known_fee", func(t *testing.T) {
		s, r := observe(t, good, "", "", true)
		if !s.FeeReady || s.Usage == nil || r.MeterDiagnostic().Usage != nil {
			t.Fatal("正常费用路径被改变或额外记录用量")
		}
	})
	t.Run("unknown_field", func(t *testing.T) {
		s, r := observe(t, good+`,"`+sensitive+`":7`, "", "", true)
		d := r.MeterDiagnostic()
		raw, _ := json.Marshal(d)
		if s.FeeReady || s.Usage != nil || d.Usage[meterName(sensitive)] != "positive_integer" || strings.Contains(string(raw), sensitive) || d.Total != "matches" {
			t.Fatal("未识别计量的拒绝或脱敏异常")
		}
	})
	t.Run("totals_and_cache", func(t *testing.T) {
		s, r := observe(t, strings.ReplaceAll(good, "4407", "1"), "", "", true)
		if s.FeeReady || s.Usage != nil || r.MeterDiagnostic().Total != "mismatch" {
			t.Fatal("不一致的总量被放行")
		}
		s, r = observe(t, `"input_tokens":1,"output_tokens":0`, "", "", true)
		if s.FeeReady || s.Usage == nil || s.Usage.Cached != nil || r.MeterDiagnostic().Total != "absent" {
			t.Fatal("未声明的缓存在诊断中被补为零")
		}
	})
	t.Run("private_metadata", func(t *testing.T) {
		s, r := observe(t, good, `,"tool_usage":{"web_search":{"query":"`+sensitive+`"}}`, meta, true)
		d := r.MeterDiagnostic()
		raw, _ := json.Marshal(d)
		if s.FeeReady || !d.Rejected["tool_usage"] || !d.Rejected["metadata"] || d.MetadataReference != "matches" || d.ToolUsage["web_search"] != "object" || strings.Contains(string(raw), sensitive) || strings.Contains(string(raw), "query") {
			t.Fatal("工具或审核信息被展开，或拒绝原因缺失")
		}
		d.ToolUsage["web_search"] = "changed"
		delete(d.Rejected, "metadata")
		if r.MeterDiagnostic().ToolUsage["web_search"] != "object" || !r.MeterDiagnostic().Rejected["metadata"] {
			t.Fatal("外部修改改变了原观察")
		}
	})
	t.Run("bounded_fields", func(t *testing.T) {
		var extras strings.Builder
		for i := 0; i < 35; i++ {
			fmt.Fprintf(&extras, `,"x%02d":0`, i)
		}
		s, r := observe(t, good+extras.String(), "", "", true)
		d := r.MeterDiagnostic()
		if s.FeeReady || d.Usage["..."] != "truncated" || d.Usage["input_tokens_details.cached_tokens"] != "positive_integer" || len(d.Usage) > 27 {
			t.Fatal("诊断没有按固定大小和层次截断")
		}
	})
	t.Run("other_routes", func(t *testing.T) {
		s, r := observe(t, good, `,"tool_usage":{}`, "", false)
		raw, _ := json.Marshal(r.MeterDiagnostic())
		if s.FeeReady || string(raw) != "{}" {
			t.Fatal("未绑定的路由生成了计量诊断或改变了费用")
		}
	})
}
