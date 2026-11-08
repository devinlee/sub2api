//go:build meton_managed

package metonresult

import (
	"encoding/json"
	"mime"
	"net/http"
	"strings"
)

/** CodexStreamRequest 只供已验证真实供应身份、已匹配执行报价的最终出站请求使用。 */
func CodexStreamRequest(request *http.Request, actual []byte) bool {
	if request == nil || request.URL == nil || request.Method != http.MethodPost ||
		request.URL.String() != "https://chatgpt.com/backend-api/codex/responses" ||
		(request.Host != "" && request.Host != request.URL.Host) {
		return false
	}
	var data struct {
		Stream bool `json:"stream"`
	}
	return json.Unmarshal(actual, &data) == nil && data.Stream
}

/** singleHeader 同名多值、不同大小写的重复声明均不参与类型推断。 */
func singleHeader(headers http.Header, key string) (string, bool) {
	var values []string
	for name, list := range headers {
		if strings.EqualFold(name, key) {
			values = append(values, list...)
		}
	}
	if len(values) == 0 {
		return "", true
	}
	if len(values) != 1 {
		return "", false
	}
	return strings.TrimSpace(values[0]), true
}

/** streamMedia 只对固定 OAuth 目标的缺省或通用媒体声明开启实际帧检查。 */
func streamMedia(header http.Header) (media, category string, requireCreated bool) {
	value, unique := singleHeader(header, "Content-Type")
	encoding, oneEncoding := singleHeader(header, "Content-Encoding")
	if !unique || !oneEncoding {
		return "invalid", "ambiguous", false
	}
	if encoding != "" && !strings.EqualFold(encoding, "identity") {
		return "invalid", "encoded", false
	}
	if value == "" {
		return "text/event-stream", "missing", true
	}
	kind, params, err := mime.ParseMediaType(value)
	if err != nil {
		return "invalid", "invalid", false
	}
	if charset, ok := params["charset"]; ok && !strings.EqualFold(charset, "utf-8") {
		return "invalid", "charset", false
	}
	switch kind {
	case "text/event-stream":
		extra := len(params)
		if _, ok := params["charset"]; ok {
			extra--
		}
		return "text/event-stream", "event_stream", extra > 0
	case "application/octet-stream", "text/plain":
		for key := range params {
			if key != "charset" {
				return "invalid", "parameters", false
			}
		}
		return "text/event-stream", "generic", true
	case "application/json":
		return value, "json", false
	default:
		return "invalid", "other", false
	}
}

/** NewSourceResponse 保留普通响应的原读取规则；受控 OAuth 流仍由同一个观察器核对真实原字节。 */
func NewSourceResponse(response *http.Response, protocol, model string, codex bool, finish func(Snapshot)) (*Reader, error) {
	media := response.Header.Get("Content-Type")
	kind := "original"
	requireCreated := false
	if codex && protocol == "responses" {
		media, kind, requireCreated = streamMedia(response.Header)
	}
	r, err := New(response.Body, protocol, model, media, response.StatusCode, finish)
	if err == nil {
		r.codexStream = codex && protocol == "responses"
		r.requireCreated = requireCreated
		r.declaredMedia = kind
	}
	return r, err
}

/** DeclaredMedia 只用于诊断，不记录供应 HTTP 头的原值。 */
func (r *Reader) DeclaredMedia() string { return r.declaredMedia }

/** moderationMetadata 只承认当前响应的审核元数据。新增费用、用量或内容字段仍须另行支持。 */
func (r *Reader) moderationMetadata(o object) bool {
	if r.identity == "" {
		return false
	}
	if reference, ok := o["response_id"]; ok && str(reference) != r.identity {
		return false
	}
	for key := range o {
		switch key {
		case "type", "response_id", "sequence_number", "metadata":
		default:
			return false
		}
	}
	if n, ok := o["sequence_number"]; ok {
		if _, valid := integer(n); !valid {
			return false
		}
	}
	fields := obj(o["metadata"])
	if fields == nil {
		return false
	}
	for key, value := range fields {
		if key != "openai_chatgpt_moderation_metadata" || obj(value) == nil {
			return false
		}
	}
	return true
}
