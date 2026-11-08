//go:build meton_managed

// Package metonresult 从实际供应响应提取有限的结束和用量事实，不定价、不写账，也不改写正文。
package metonresult

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash"
	"io"
	"mime"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
)

// MaxMetadataBytes 是一份 JSON 或 SSE 事件的观察上限；超限不截断用户内容，但费用保持未知。
const MaxMetadataBytes = 1024 * 1024

// Usage 只含供应明确报告的累计 token。缓存缺失用 nil，不能默认为零后按普通输入计费。
type Usage struct {
	Input  int64  `json:"input"`
	Output int64  `json:"output"`
	Cached *int64 `json:"cached"`
}

// Snapshot 不含正文、工具参数、凭据或用户输入。ReadEnd 只说明来源读取，不能冒充客户端交付确认。
type Snapshot struct {
	FormatVersion int    `json:"format_version"`
	Protocol      string `json:"protocol"`
	Execution     string `json:"execution"`
	Terminal      string `json:"terminal"`
	ResponseID    string `json:"response_id"`
	Usage         *Usage `json:"usage"`
	FeeReady      bool   `json:"fee_ready"`
	ReadEnd       string `json:"read_end"`
	BodySHA256    string `json:"body_sha256"`
}

// Reader 在下游实际读取时观察相同字节，不预读、不排队，也不另开后台排空正文。
type Reader struct {
	customerTokenPrice bool
	supplierAttribution string
	body      io.ReadCloser
	model     string
	protocol  string
	sse       bool
	digest    hash.Hash
	line      []byte
	data      []byte
	event     string
	cr        bool
	bad       bool
	terminal  string
	execution string
	identity  string
	usage     *Usage
	codexStream    bool
	requireCreated bool
	seenCreated    bool
	shape MeterShape
	declaredMedia  string
	issue     string
	feeBad    bool
	done      bool
	finish    func(Snapshot)
	once      sync.Once
	finished  bool
	mu        sync.Mutex
}

/** New 绑定实际出站协议与模型；HTTP 200、合法结束、完整用量分别核验，不能互相替代。 */
func New(body io.ReadCloser, protocol, model, contentType string, status int, finish func(Snapshot)) (*Reader, error) {
	if body == nil || finish == nil || model == "" || (protocol != "responses" && protocol != "chat_completions") {
		return nil, errors.New("invalid original response observer")
	}
	media, params, err := mime.ParseMediaType(contentType)
	valid := err == nil && (media == "text/event-stream" || media == "application/json") &&
		len(params) <= 1 && (len(params) == 0 || strings.EqualFold(params["charset"], "utf-8"))
	issue := ""
	if status != 200 {
		issue = "http_status"
	} else if !valid {
		issue = "media_type"
	}
	return &Reader{issue: issue, body: body, model: model, protocol: protocol, sse: media == "text/event-stream", digest: sha256.New(),
		bad: !valid || status != 200, execution: "unknown", finish: finish}, nil
}

/** Read 保持原 Read 的 n、err 和字节；即使同一读同时交回末尾字节与 EOF，也先核对这些字节。 */
func (r *Reader) Read(p []byte) (int, error) {
	n, err := r.body.Read(p)
	r.mu.Lock()
	if !r.finished {
		_, _ = r.digest.Write(p[:n])
		r.feed(p[:n])
	}
	r.mu.Unlock()
	if err != nil {
		end := "read_error"
		if err == io.EOF {
			end = "eof"
		}
		r.complete(end)
	}
	return n, err
}

/** Close 不为了凑齐费用证据再读网络；并发关闭和读完只交付同一份观察。 */
func (r *Reader) Close() error {
	err := r.body.Close()
	r.complete("closed")
	return err
}

func (r *Reader) complete(end string) {
	r.once.Do(func() {
		r.mu.Lock()
		if !r.sse && end == "eof" && !r.bad {
			r.consume(r.data, "")
		}
		// SSE 未以空行结束的事件尚未交付；关闭或 EOF 均不能补造该事件。
		if r.sse && (len(r.line) != 0 || len(r.data) != 0 || r.event != "") {
			r.markIssue("partial_sse_event")
			r.bad = true
		}
		state, terminal, usage := r.execution, r.terminal, r.usage
		if r.bad {
			state, terminal, usage = "unknown", "", nil
		}
		ready := !r.bad && !r.feeBad && terminal != "" && usage != nil && usage.Cached != nil &&
			(r.protocol == "responses" || !r.sse || r.done)
		// Chat 的 finish_reason 不是 SSE 结束；只有原 [DONE] 才能确认完整终局。
		if r.protocol == "chat_completions" && r.sse && !r.done {
			state, terminal = "unknown", ""
		}
		s := Snapshot{1, r.protocol, state, terminal, r.identity, usage, ready, end, hex.EncodeToString(r.digest.Sum(nil))}
		r.finished = true
		r.line, r.data, r.usage = nil, nil, nil
		r.mu.Unlock()
		r.finish(s)
	})
}

func (r *Reader) invalidate() {
	r.markIssue("protocol_shape")
	r.bad = true
	r.line, r.data = nil, nil
}

func (r *Reader) feed(p []byte) {
	if r.bad {
		return
	}
	if !r.sse {
		if len(p) > MaxMetadataBytes-len(r.data) {
			r.invalidate()
		} else {
			r.data = append(r.data, p...)
		}
		return
	}
	for _, b := range p {
		if r.cr && b == '\n' {
			r.cr = false
			continue
		}
		r.cr = false
		if b == '\r' || b == '\n' {
			r.consumeLine()
			r.line = r.line[:0]
			r.cr = b == '\r'
		} else if len(r.line)+len(r.data) >= MaxMetadataBytes {
			r.invalidate()
		} else {
			r.line = append(r.line, b)
		}
		if r.bad {
			return
		}
	}
}

func (r *Reader) consumeLine() {
	if !utf8.Valid(r.line) {
		r.invalidate()
		return
	}
	if len(r.line) == 0 {
		if len(r.data) > 0 {
			r.consume(bytes.TrimSuffix(r.data, []byte{'\n'}), r.event)
		}
		r.data = r.data[:0]
		r.event = ""
		return
	}
	if r.line[0] == ':' {
		return
	}
	field, value, _ := bytes.Cut(r.line, []byte{':'})
	value = bytes.TrimPrefix(value, []byte{' '})
	switch string(field) {
	case "data":
		if len(value)+1 > MaxMetadataBytes-len(r.data) {
			r.invalidate()
			return
		}
		r.data = append(r.data, value...)
		r.data = append(r.data, '\n')
	case "event":
		if r.event != "" || len(value) > 120 {
			r.invalidate()
			return
		}
		r.event = string(value)
	case "id", "retry":
		// 供应重连提示不能授予新的生成或续传权限。
	default:
		r.invalidate()
	}
}

type object map[string]json.RawMessage

func obj(raw []byte) object {
	var o object
	if len(raw) == 0 || json.Unmarshal(raw, &o) != nil {
		return nil
	}
	return o
}

func str(raw []byte) string {
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
}

func integer(raw []byte) (int64, bool) {
	s := string(raw)
	if s == "" || len(s) > 9 || (len(s) > 1 && s[0] == '0') {
		return 0, false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil && n <= 100000000
}

func present(raw []byte) bool { return len(raw) > 0 && string(raw) != "null" }

func (r *Reader) bind(o object) bool {
	id := str(o["id"])
	if id == "" || len(id) > 256 {
		r.markIssue("response_id_invalid")
		return false
	}
	if str(o["model"]) != r.model {
		r.markIssue("response_model_mismatch")
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-_.:", c)) {
			return false
		}
	}
	if r.identity != "" && r.identity != id {
		r.markIssue("response_id_changed")
		return false
	}
	r.identity = id
	return true
}

func (r *Reader) consume(raw []byte, event string) {
	if r.bad {
		return
	}
	if bytes.Equal(raw, []byte("[DONE]")) {
		if !r.sse || r.done || r.terminal == "" || event != "" {
			r.invalidate()
		} else {
			r.done = true
		}
		return
	}
	var o object
	if r.done || r.execution == "failed" && r.terminal == "" || metonexecution.DecodeStrict(raw, &o) != nil || o == nil {
		r.invalidate()
		return
	}
	if present(o["error"]) && (r.sse || r.protocol == "chat_completions" || !present(o["status"])) || str(o["type"]) == "error" {
		if r.terminal != "" {
			r.invalidate()
		} else {
			r.execution = "failed"
			r.feeBad = true
		}
		return
	}
	if r.protocol == "responses" {
		r.responses(o, event)
	} else {
		r.chat(o, event)
	}
}

func (r *Reader) responses(o object, event string) {
	terminal := ""
	response := o
	if r.sse {
		kind := str(o["type"])
		if kind == "" || (event != "" && event != kind) || r.terminal != "" {
			r.invalidate()
			return
		}
		if r.codexStream && kind == "response.metadata" {
			if !r.moderationMetadata(o) {
				r.meterMetadata(o)
				r.rejectMeter("metadata")
				r.markIssue("unsupported_fee_metadata")
			}
			return
		}
		switch kind {
		case "response.completed", "response.failed", "response.incomplete", "response.cancelled":
			terminal = strings.TrimPrefix(kind, "response.")
		default:
			if !strings.HasPrefix(kind, "response.") {
				r.markIssue("foreign_event")
				r.invalidate()
			}
			switch kind {
			case "response.created", "response.in_progress", "response.output_item.added", "response.output_item.done",
				"response.content_part.added", "response.content_part.done", "response.output_text.delta", "response.output_text.done",
				"response.refusal.delta", "response.refusal.done", "response.function_call_arguments.delta", "response.function_call_arguments.done",
				"response.reasoning_summary_part.added", "response.reasoning_summary_part.done", "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
				"response.reasoning_text.delta", "response.reasoning_text.done":
			default:
				r.rejectMeter("stream_event")
			}
			if item := obj(o["item"]); item != nil {
				if k := str(item["type"]); k != "message" && k != "function_call" && k != "reasoning" {
					r.rejectMeter("stream_item")
				}
			}
			if raw := o["response"]; present(raw) {
				inner := obj(raw)
				if !r.bind(inner) {
					r.invalidate()
				} else if kind == "response.created" && (str(inner["status"]) == "in_progress" || str(inner["status"]) == "queued") {
					r.seenCreated = true
				}
			}
			return
		}
		if r.requireCreated && !r.seenCreated {
			r.markIssue("protocol_shape")
			r.invalidate()
			return
		}
		response = obj(o["response"])
	} else {
		terminal = str(response["status"])
	}
	if terminal != "completed" && terminal != "failed" && terminal != "incomplete" && terminal != "cancelled" ||
		!r.bind(response) || str(response["status"]) != terminal || (terminal == "completed" && present(response["error"])) {
		r.invalidate()
		return
	}
	var output []object
	if json.Unmarshal(response["output"], &output) != nil || output == nil {
		r.rejectMeter("output_shape")
	}
	for _, item := range output {
		switch str(item["type"]) {
		case "function_call", "reasoning":
		case "message":
			var contents []object
			if json.Unmarshal(item["content"], &contents) != nil {
				r.rejectMeter("content_shape")
			}
			for _, c := range contents {
				if str(c["type"]) != "output_text" && str(c["type"]) != "refusal" {
					r.rejectMeter("content_type")
				}
			}
		default:
			r.rejectMeter("output_type")
		}
	}
	if raw := response["tool_usage"]; present(raw) && (!r.codexStream || !zeroHostedTools(raw)) {
		r.rejectMeter("tool_usage")
	}
	r.terminal = "response." + terminal
	r.execution = "failed"
	if terminal == "completed" {
		r.execution = "completed"
	}
	r.usage = r.responseUsage(response["usage"])
	if r.codexStream && (r.feeBad || r.usage == nil || r.usage.Cached == nil) {
		r.meterTerminal(response)
	}
}

func (r *Reader) chat(o object, event string) {
	if event != "" && event != "message" || !r.bind(o) || str(o["object"]) != map[bool]string{true: "chat.completion.chunk", false: "chat.completion"}[r.sse] {
		r.invalidate()
		return
	}
	var choices []object
	if json.Unmarshal(o["choices"], &choices) != nil || choices == nil || len(choices) > 1 {
		r.invalidate()
		return
	}
	if len(choices) == 0 && (!r.sse || r.terminal == "" || !present(o["usage"])) {
		r.invalidate()
		return
	}
	if len(choices) == 1 {
		c := choices[0]
		index, ok := integer(c["index"])
		if !ok || index != 0 || r.terminal != "" {
			r.invalidate()
			return
		}
		body := obj(c["message"])
		if r.sse {
			body = obj(c["delta"])
		}
		if body == nil {
			r.invalidate()
			return
		}
		if present(body["audio"]) {
			r.feeBad = true
		}
		if present(body["annotations"]) {
			var annotations []json.RawMessage
			if json.Unmarshal(body["annotations"], &annotations) != nil || len(annotations) != 0 {
				r.feeBad = true
			}
		}
		reason := str(c["finish_reason"])
		if present(c["finish_reason"]) && reason == "" {
			r.invalidate()
			return
		}
		if reason != "" {
			switch reason {
			case "stop", "tool_calls", "function_call":
				r.execution = "completed"
			case "length", "content_filter":
				r.execution = "failed"
			default:
				r.invalidate()
				return
			}
			r.terminal = "chat." + reason
		} else if !r.sse {
			r.invalidate()
			return
		}
	}
	if present(o["usage"]) {
		u := usageFields(obj(o["usage"]), true, false)
		// 单条完整累计用量才是终局；中途或重复的不同报告不能“最后一个覆盖前一个”。
		if r.terminal == "" || u == nil || r.usage != nil && !sameUsage(r.usage, u) {
			r.feeBad = true
		} else {
			r.usage = u
		}
	}
}

func sameUsage(a, b *Usage) bool {
	return a.Input == b.Input && a.Output == b.Output && (a.Cached == nil && b.Cached == nil || a.Cached != nil && b.Cached != nil && *a.Cached == *b.Cached)
}

func usageFields(u object, chat, zeroCacheWrite bool) *Usage {
	input, output, details := "input_tokens", "output_tokens", "input_tokens_details"
	if chat {
		input, output, details = "prompt_tokens", "completion_tokens", "prompt_tokens_details"
	}
	in, a := integer(u[input])
	out, b := integer(u[output])
	if !a || !b {
		return nil
	}
	if present(u["total_tokens"]) {
		total, ok := integer(u["total_tokens"])
		if !ok || total != in+out {
			return nil
		}
	}
	outputDetails := "output_tokens_details"
	if chat {
		outputDetails = "completion_tokens_details"
	}
	for k := range u {
		if k != input && k != output && k != "total_tokens" && k != details && k != outputDetails {
			return nil
		}
	}
	result := &Usage{Input: in, Output: out}
	for _, name := range []string{details, outputDetails} {
		if !present(u[name]) {
			continue
		}
		d := obj(u[name])
		if d == nil {
			return nil
		}
		for k, value := range d {
			n, ok := integer(value)
			if !ok {
				return nil
			}
			// 已固定的文本价格不含缓存写入。只有供应显式报告零次才能略过该项。
			if zeroCacheWrite && name == details && k == "cache_write_tokens" && n == 0 {
				continue
			}
			if name == details && k == "cached_tokens" {
				if n > in {
					return nil
				}
				result.Cached = &n
			} else if name == outputDetails && (k == "reasoning_tokens" || k == "accepted_prediction_tokens" || k == "rejected_prediction_tokens") {
				if n > out {
					return nil
				}
			} else {
				// 音频、图片和未来新增计量不属于已发布文本价格，不能漏项后自动结清。
				return nil
			}
		}
	}
	return result
}
