//go:build meton_managed

package metonresult

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"maps"
	"sort"
)

// MeterShape 只用于定位原观察。不能写费用、推断缺省值，也不能代替可信供应回执。
type MeterShape struct {
	Usage             map[string]string `json:"usage,omitempty"`
	ToolUsage         map[string]string `json:"tool_usage,omitempty"`
	Metadata          map[string]string `json:"metadata,omitempty"`
	Total             string            `json:"total_check,omitempty"`
	MetadataReference string            `json:"metadata_reference,omitempty"`
	Rejected          map[string]bool   `json:"rejected,omitempty"`
}

/** meterName 只原样公开协议白名单中的字段名，扩展键的前缀摘要可与获准样本离线比对。 */
func meterName(key string) string {
	switch key {
	case "type", "response_id", "sequence_number", "metadata", "openai_chatgpt_moderation_metadata",
		"input_tokens", "output_tokens", "total_tokens", "input_tokens_details", "output_tokens_details",
		"prompt_tokens", "completion_tokens", "prompt_tokens_details", "completion_tokens_details",
		"cached_tokens", "reasoning_tokens", "accepted_prediction_tokens", "rejected_prediction_tokens",
		"audio_tokens", "image_tokens", "video_tokens", "text_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
		"web_search", "image_generation", "num_requests", "count", "obfuscation", "tool_calls":
		return key
	default:
		sum := sha256.Sum256([]byte(key))
		return "field_" + hex.EncodeToString(sum[:8])
	}
}

/** valueShape 对数值只区分零、正整数、其他数值。字符串、数组和业务对象的原始值留在内存读取范围。 */
func valueShape(raw json.RawMessage) string {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return "absent"
	}
	switch raw[0] {
	case '{':
		if len(raw) >= 2 && len(bytes.TrimSpace(raw[1:len(raw)-1])) == 0 {
			return "empty_object"
		}
		return "object"
	case '[':
		return "array"
	case '"':
		return "string"
	case 'n':
		return "null"
	case 't', 'f':
		return "boolean"
	default:
		if n, ok := integer(raw); ok {
			if n == 0 {
				return "zero"
			}
			return "positive_integer"
		}
		return "other_number"
	}
}

/** shapeFields 限制条目及层数。只向下查看明确的 token 明细字段，审核材料和工具参数都不展开。 */
func shapeFields(raw json.RawMessage, details bool) map[string]string {
	result := map[string]string{"$": valueShape(raw)}
	describeFields(result, obj(raw), details)
	return result
}

/** describeFields 只查看对象的键。审核信息在上层已解析，避免再复制整份内容。 */
func describeFields(result map[string]string, fields object, details bool) {
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for i, key := range keys {
		if i >= 24 {
			result["..."] = "truncated"
			break
		}
		name := meterName(key)
		result[name] = valueShape(fields[key])
		if details && (name == "input_tokens_details" || name == "output_tokens_details" || name == "prompt_tokens_details" || name == "completion_tokens_details") {
			for sub, value := range shapeFields(fields[key], false) {
				if sub != "$" {
					result[name+"."+sub] = value
				}
			}
		}
	}
}

/** meterTerminal 在原读取锁内登记终局形状。三项数量是否守恒单独描述，缺少绝不推为零。 */
func (r *Reader) meterTerminal(response object) {
	r.shape.Usage = shapeFields(response["usage"], true)
	r.shape.ToolUsage = shapeFields(response["tool_usage"], false)
	u := obj(response["usage"])
	if r.shape.Rejected["usage_attribution"] {
		// 留下有限的子字段类型。扩展值、原文、账号及凭据均不出现在诊断里。
		for name, kind := range shapeFields(u["attribution"], false) {
			if name != "$" {
				r.shape.Usage["attribution."+name] = kind
			}
		}
	}
	in, a := integer(u["input_tokens"])
	out, b := integer(u["output_tokens"])
	total, c := integer(u["total_tokens"])
	switch {
	case !present(u["total_tokens"]):
		r.shape.Total = "absent"
	case !a || !b || !c:
		r.shape.Total = "invalid"
	case in+out == total:
		r.shape.Total = "matches"
	default:
		r.shape.Total = "mismatch"
	}
}

/** meterMetadata 只记录最外层协议类别和编号是否为原响应，不保留编号与审核内容。 */
func (r *Reader) meterMetadata(envelope object) {
	fields := map[string]string{"$": "object"}
	describeFields(fields, envelope, false)
	for name, kind := range shapeFields(envelope["metadata"], false) {
		if name != "$" {
			fields["metadata."+name] = kind
		}
	}
	r.shape.Metadata = fields
	switch {
	case !present(envelope["response_id"]):
		r.shape.MetadataReference = "absent"
	case r.identity != "" && str(envelope["response_id"]) == r.identity:
		r.shape.MetadataReference = "matches"
	default:
		r.shape.MetadataReference = "mismatch"
	}
}

/** rejectMeter 在原拒绝点保持相同收费结果，仅对绑定的流记下触发的固定分支。 */
func (r *Reader) rejectMeter(part string) {
	r.feeBad = true
	if r.codexStream {
		if r.shape.Rejected == nil {
			r.shape.Rejected = map[string]bool{}
		}
		r.shape.Rejected[part] = true
	}
}

/** MeterDiagnostic 在原观察完成后由来源日志读取独立副本，返回对象不参与任何账务判定。 */
func (r *Reader) MeterDiagnostic() MeterShape {
	r.mu.Lock()
	defer r.mu.Unlock()
	value := r.shape
	value.Usage = maps.Clone(value.Usage)
	value.ToolUsage = maps.Clone(value.ToolUsage)
	value.Metadata = maps.Clone(value.Metadata)
	value.Rejected = maps.Clone(value.Rejected)
	return value
}
