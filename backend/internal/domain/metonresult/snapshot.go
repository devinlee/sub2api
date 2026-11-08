//go:build meton_managed

package metonresult

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

/** Unavailable 表示实际网络已尝试但没有可读响应；不能据此证明未执行或免除费用。 */
func Unavailable(protocol string) Snapshot {
	digest := sha256.Sum256(nil)
	return Snapshot{FormatVersion: 1, Protocol: protocol, Execution: "unknown", ReadEnd: "read_error", BodySHA256: hex.EncodeToString(digest[:])}
}

/** Valid 只核对回执形状与内部一致性；可信来源和原请求归属必须由仓储另外核验。 */
func (s Snapshot) Valid() bool {
	if s.FormatVersion != 1 || (s.Protocol != "responses" && s.Protocol != "chat_completions") ||
		(s.Execution != "unknown" && s.Execution != "completed" && s.Execution != "failed") ||
		(s.ReadEnd != "eof" && s.ReadEnd != "closed" && s.ReadEnd != "read_error") || len(s.ResponseID) > 256 {
		return false
	}
	digest, err := hex.DecodeString(s.BodySHA256)
	if err != nil || len(digest) != 32 || hex.EncodeToString(digest) != s.BodySHA256 {
		return false
	}
	for _, c := range s.ResponseID {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-_.:", c)) {
			return false
		}
	}
	if s.Terminal == "" {
		if s.Execution == "completed" || s.FeeReady {
			return false
		}
	} else {
		complete, valid := false, false
		if s.Protocol == "responses" {
			complete = s.Terminal == "response.completed"
			valid = complete || s.Terminal == "response.failed" || s.Terminal == "response.incomplete" || s.Terminal == "response.cancelled"
		} else {
			complete = s.Terminal == "chat.stop" || s.Terminal == "chat.tool_calls" || s.Terminal == "chat.function_call"
			valid = complete || s.Terminal == "chat.length" || s.Terminal == "chat.content_filter"
		}
		if !valid || s.Execution != map[bool]string{true: "completed", false: "failed"}[complete] {
			return false
		}
	}
	if u := s.Usage; u != nil && (u.Input < 0 || u.Input > 100000000 || u.Output < 0 || u.Output > 100000000 ||
		u.Cached != nil && (*u.Cached < 0 || *u.Cached > u.Input)) {
		return false
	}
	return !s.FeeReady || s.ResponseID != "" && s.Usage != nil && s.Usage.Cached != nil
}
