//go:build meton_managed

package metonresult

import "encoding/json"

/** responseUsage 保留原供应明确给出的文本计量；原预占的用户费率决定额外归属字段的处理。 */
func (r *Reader) responseUsage(raw json.RawMessage) *Usage {
	fields := obj(raw)
	extension, exists := fields["attribution"]
	if !exists || !r.codexStream || !r.sse {
		return usageFields(fields, false, r.codexStream)
	}
	plainText := !r.feeBad && r.seenCreated && r.terminal == "response.completed"
	if !r.customerTokenPrice {
		r.rejectMeter("usage_attribution")
	}
	if !plainText || len(obj(extension)) == 0 {
		return nil
	}
	if _, valid := integer(fields["total_tokens"]); !valid {
		return nil
	}
	// fields 只属于本次解码。复用原解析器检查其余每个字段和总量，原字节与预占均保留。
	delete(fields, "attribution")
	known := usageFields(fields, false, true)
	if known == nil || known.Cached == nil {
		return nil
	}
	if r.customerTokenPrice {
		r.rememberAttribution(extension)
	}
	return known
}
