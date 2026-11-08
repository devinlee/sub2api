//go:build meton_managed

package metonresult

import "strings"

/** markIssue 记录首个固定原因。调用处持有读取锁，不保存事件名、响应正文或模型别名。 */
func (r *Reader) markIssue(reason string) {
	if r.issue == "" {
		r.issue = reason
	}
}

/** IncompleteReason 在原观察交付后返回定位信息，不更改观察、写账权限或原请求。 */
func (r *Reader) IncompleteReason(s Snapshot) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	switch {
	case s.FeeReady:
		return "none"
	case r.issue != "":
		return r.issue
	case r.bad:
		return "protocol_shape"
	case s.Terminal == "" && s.ReadEnd == "read_error":
		return "transport_read_error"
	case s.Terminal == "":
		return "missing_terminal"
	case r.feeBad:
		return "unsupported_fee_metadata"
	default:
		return "incomplete_usage"
	}
}

/** EncodingClass 只保留固定压缩类型，任意上游头值不能进入运行日志。 */
func EncodingClass(header string) string {
	switch strings.ToLower(strings.TrimSpace(header)) {
	case "", "identity":
		return "identity"
	case "gzip":
		return "gzip"
	case "br":
		return "br"
	case "zstd":
		return "zstd"
	default:
		return "other"
	}
}
