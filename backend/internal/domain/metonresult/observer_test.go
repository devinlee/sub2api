//go:build unit && meton_managed

package metonresult

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
)

const response = `{"id":"resp_one","object":"response","model":"text-fixture","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"你好🙂"}]},{"type":"function_call","name":"read","arguments":"{\"path\":\"a\"}"}],"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6,"input_tokens_details":{"cached_tokens":1},"output_tokens_details":{"reasoning_tokens":1}}}`
const chat = `{"id":"chat_one","object":"chat.completion","model":"text-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"你好🙂","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":"{\"path\":\"a\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6,"prompt_tokens_details":{"cached_tokens":1},"completion_tokens_details":{"reasoning_tokens":1}}}`

func responsesStream() string {
	return "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"你好🙂\"}\n\n" +
		"data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"path\\\":\\\"\"}\n\n" +
		"data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"a\\\"}\"}\n\n" +
		"event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":" + response + "}\n\n"
}

func chatStream() string {
	return "data: {\"id\":\"chat_one\",\"object\":\"chat.completion.chunk\",\"model\":\"text-fixture\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好🙂\",\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"\"}}]},\"finish_reason\":null}]}\n\n" +
		"data: {\"id\":\"chat_one\",\"object\":\"chat.completion.chunk\",\"model\":\"text-fixture\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"a\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n" +
		"data: {\"id\":\"chat_one\",\"object\":\"chat.completion.chunk\",\"model\":\"text-fixture\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6,\"prompt_tokens_details\":{\"cached_tokens\":1}}}\n\n" +
		"data: [DONE]\n\n"
}

type chunkBody struct {
	raw    []byte
	step   int
	end    error
	reads  int
	closed bool
}

func (b *chunkBody) Read(p []byte) (int, error) {
	b.reads++
	n := min(len(p), len(b.raw), b.step)
	copy(p, b.raw[:n])
	b.raw = b.raw[n:]
	if len(b.raw) == 0 {
		return n, b.end
	}
	return n, nil
}
func (b *chunkBody) Close() error { b.closed = true; return nil }

func observe(t *testing.T, proto, content string, sse bool, step int, end error) Snapshot {
	t.Helper()
	body := &chunkBody{raw: []byte(content), step: step, end: end}
	media := "application/json"
	if sse {
		media = "text/event-stream; charset=utf-8"
	}
	var got Snapshot
	calls := 0
	r, err := New(body, proto, "text-fixture", media, 200, func(s Snapshot) { got = s; calls++ })
	if err != nil || body.reads != 0 {
		t.Fatal("构造不得预读", err)
	}
	actual, readErr := io.ReadAll(r)
	if !bytes.Equal(actual, []byte(content)) || (end == io.EOF && readErr != nil) || (end != io.EOF && readErr != end) {
		t.Fatal("观察改变了正文或原错误", readErr)
	}
	if err := r.Close(); err != nil || calls != 1 || !body.closed {
		t.Fatal("读完与关闭必须只回报一次", err, calls)
	}
	if err := r.Close(); err != nil || calls != 1 {
		t.Fatal("重复关闭产生第二份观察", err)
	}
	if !got.Valid() {
		t.Fatal("实际观察不满足持久回执形状", got)
	}
	h := sha256.Sum256(actual)
	if got.BodySHA256 != hex.EncodeToString(h[:]) {
		t.Fatal("摘要不是实际经过的字节")
	}
	raw, _ := json.Marshal(got)
	if bytes.Contains(raw, []byte("你好")) || bytes.Contains(raw, []byte("arguments")) || bytes.Contains(raw, []byte("path")) {
		t.Fatal("观察泄露正文或工具参数")
	}
	return got
}

func TestModelResultEveryByteBoundary(t *testing.T) {
	for _, c := range []struct {
		name, proto, content string
		sse                  bool
	}{{"responses_json", "responses", response, false}, {"chat_json", "chat_completions", chat, false},
		{"responses_sse", "responses", responsesStream(), true}, {"chat_sse", "chat_completions", chatStream(), true}} {
		t.Run(c.name, func(t *testing.T) {
			for step := 1; step <= len(c.content)+1; step++ {
				s := observe(t, c.proto, c.content, c.sse, step, io.EOF)
				if s.Execution != "completed" || !s.FeeReady || s.Usage == nil || s.Usage.Input != 4 || s.Usage.Output != 2 || s.Usage.Cached == nil || *s.Usage.Cached != 1 {
					t.Fatalf("合法终局在分块 %d 被误判: %+v", step, s)
				}
			}
		})
	}
}

func TestModelResultSSEFraming(t *testing.T) {
	for name, value := range map[string]string{
		"crlf":      strings.ReplaceAll(responsesStream(), "\n", "\r\n"),
		"cr":        strings.ReplaceAll(responsesStream(), "\n", "\r"),
		"comments":  ": heartbeat\nid: no-resume\nretry: 1\n\n" + responsesStream(),
		"multiline": strings.Replace(responsesStream(), `,"response":`, ",\ndata: \"response\":", 1),
		"done":      responsesStream() + "data: [DONE]\n\n",
	} {
		t.Run(name, func(t *testing.T) {
			if s := observe(t, "responses", value, true, 1, io.EOF); !s.FeeReady {
				t.Fatal(s)
			}
		})
	}
}

func TestModelResultMissingIsNotZero(t *testing.T) {
	for name, raw := range map[string]string{
		"missing_usage":   strings.Replace(response, `"usage":`, `"unreported":`, 1),
		"missing_input":   strings.Replace(response, `"input_tokens":4`, `"missing":4`, 1),
		"null_input":      strings.Replace(response, `"input_tokens":4`, `"input_tokens":null`, 1),
		"missing_output":  strings.Replace(response, `"output_tokens":2`, `"missing":2`, 1),
		"missing_cached":  strings.Replace(response, `"input_tokens_details":{"cached_tokens":1}`, `"input_tokens_details":{}`, 1),
		"null_details":    strings.Replace(response, `"input_tokens_details":{"cached_tokens":1}`, `"input_tokens_details":null`, 1),
		"unknown_counter": strings.Replace(response, `"input_tokens":4`, `"input_tokens":4,"image_tokens":1`, 1),
		"media":           strings.Replace(response, `"cached_tokens":1`, `"cached_tokens":1,"audio_tokens":1`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if s := observe(t, "responses", raw, false, 7, io.EOF); s.FeeReady || s.Execution != "completed" {
				t.Fatal("执行与费用未知未分离", s)
			}
		})
	}
	raw := strings.ReplaceAll(response, `"input_tokens":4`, `"input_tokens":0`)
	raw = strings.ReplaceAll(raw, `"output_tokens":2`, `"output_tokens":0`)
	raw = strings.ReplaceAll(raw, `"total_tokens":6`, `"total_tokens":0`)
	raw = strings.ReplaceAll(raw, `"cached_tokens":1`, `"cached_tokens":0`)
	raw = strings.ReplaceAll(raw, `"reasoning_tokens":1`, `"reasoning_tokens":0`)
	if s := observe(t, "responses", raw, false, 1, io.EOF); !s.FeeReady || s.Usage.Input != 0 || s.Usage.Output != 0 {
		t.Fatal("明确零用量没有保留", s)
	}
}

func TestModelResultInvalidUsage(t *testing.T) {
	for _, v := range []string{`-1`, `"4"`, `4.0`, `4e0`, `true`, `null`, `100000001`, `99999999999999999999`} {
		t.Run(v, func(t *testing.T) {
			if s := observe(t, "responses", strings.Replace(response, `"input_tokens":4`, `"input_tokens":`+v, 1), false, 13, io.EOF); s.FeeReady || s.Usage != nil {
				t.Fatal("非法用量进入待结算", s)
			}
		})
	}
	for _, c := range [][3]string{
		{"cached_exceeds_input", `"cached_tokens":1`, `"cached_tokens":5`},
		{"reasoning_exceeds_output", `"reasoning_tokens":1`, `"reasoning_tokens":3`},
		{"total_mismatch", `"total_tokens":6`, `"total_tokens":7`},
		{"duplicate_usage", `"input_tokens":4`, `"input_tokens":4,"input_tokens":0`},
		{"nested_duplicate", `"cached_tokens":1`, `"cached_tokens":1,"cached_tokens":0`},
		{"wrong_case", `"input_tokens":4`, `"INPUT_TOKENS":4`},
	} {
		t.Run(c[0], func(t *testing.T) {
			if s := observe(t, "responses", strings.Replace(response, c[1], c[2], 1), false, 5, io.EOF); s.FeeReady {
				t.Fatal("冲突或非法用量进入结算", s)
			}
		})
	}
}

func TestModelResultTerminationFailures(t *testing.T) {
	for name, raw := range map[string]string{
		"no_terminal":         strings.Split(responsesStream(), "event: response.completed")[0],
		"missing_status":      strings.Replace(responsesStream(), `"status":"completed"`, `"unreported_status":"completed"`, 1),
		"wrong_status":        strings.Replace(responsesStream(), `"status":"completed"`, `"status":"failed"`, 1),
		"missing_response":    "data: {\"type\":\"response.completed\"}\n\n",
		"unfinished_event":    strings.TrimSuffix(responsesStream(), "\n"),
		"duplicate_terminal":  responsesStream() + responsesStream(),
		"only_done":           "data: [DONE]\n\n",
		"event_type_conflict": strings.Replace(responsesStream(), "event: response.completed", "event: response.failed", 1),
		"after_done":          responsesStream() + "data: [DONE]\n\n" + "data: {\"type\":\"response.failed\"}\n\n",
		"wrong_model":         strings.Replace(responsesStream(), `"model":"text-fixture"`, `"model":"foreign"`, 1),
		"changed_response":    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"other\",\"model\":\"text-fixture\"}}\n\n" + responsesStream(),
		"trailing_error":      responsesStream() + "data: {\"type\":\"error\",\"error\":{\"message\":\"secret prompt\"}}\n\n",
		"invalid_utf8":        strings.Replace(responsesStream(), "你好", "\xff", 1),
	} {
		t.Run(name, func(t *testing.T) {
			s := observe(t, "responses", raw, true, 3, io.EOF)
			if s.Execution == "completed" || s.FeeReady {
				t.Fatal("无完整终局却完成或放行费用", s)
			}
		})
	}
}

func TestModelResultChatTerminationFailures(t *testing.T) {
	for name, raw := range map[string]string{
		"no_done":             strings.Replace(chatStream(), "data: [DONE]\n\n", "", 1),
		"no_finish_reason":    strings.Replace(chatStream(), `"finish_reason":"tool_calls"`, `"finish_reason":null`, 1),
		"foreign_choice":      strings.Replace(chatStream(), `"index":0`, `"index":1`, 1),
		"changed_id":          strings.Replace(chatStream(), `"id":"chat_one"`, `"id":"other"`, 1),
		"finish_twice":        strings.Replace(chatStream(), `"finish_reason":null`, `"finish_reason":"stop"`, 1),
		"unrecognized_finish": strings.Replace(chatStream(), `"finish_reason":"tool_calls"`, `"finish_reason":"unknown"`, 1),
		"json_no_finish":      strings.Replace(chat, `"finish_reason":"tool_calls"`, `"finish_reason":null`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			s := observe(t, "chat_completions", raw, name != "json_no_finish", 11, io.EOF)
			if s.FeeReady || s.Execution == "completed" {
				t.Fatal("Chat 终局不完整却放行", s)
			}
		})
	}
}

func TestModelResultFailedExecutionMayHaveKnownUsage(t *testing.T) {
	for _, terminal := range []string{"failed", "incomplete", "cancelled"} {
		t.Run(terminal, func(t *testing.T) {
			raw := strings.ReplaceAll(responsesStream(), "completed", terminal)
			if s := observe(t, "responses", raw, true, 2, io.EOF); s.Execution != "failed" || !s.FeeReady {
				t.Fatal("合法失败终局的明确实耗被抹掉", s)
			}
		})
	}
	for _, reason := range []string{"length", "content_filter"} {
		t.Run(reason, func(t *testing.T) {
			if s := observe(t, "chat_completions", strings.Replace(chatStream(), `"finish_reason":"tool_calls"`, `"finish_reason":"`+reason+`"`, 1), true, 2, io.EOF); s.Execution != "failed" || !s.FeeReady {
				t.Fatal(s)
			}
		})
	}
}

func TestModelResultOtherBillableItemsStayUnknown(t *testing.T) {
	for name, value := range map[string]string{
		"image_output": strings.Replace(response, `"type":"function_call"`, `"type":"image_generation_call"`, 1),
		"audio_output": strings.Replace(response, `"type":"output_text"`, `"type":"output_audio"`, 1),
		"tool_usage":   strings.Replace(response, `"usage":`, `"tool_usage":{"search":1},"usage":`, 1),
		"unknown_sse":  "data: {\"type\":\"response.web_search_call.completed\"}\n\n" + responsesStream(),
		"item_added":   "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"web_search_call\"}}\n\n" + responsesStream(),
	} {
		t.Run(name, func(t *testing.T) {
			if s := observe(t, "responses", value, name == "unknown_sse" || name == "item_added", 9, io.EOF); s.FeeReady {
				t.Fatal("不属于文本价格的费用被漏项结清", s)
			}
		})
	}
}

func TestModelResultReadErrorAndTerminalIndependent(t *testing.T) {
	broken := errors.New("synthetic upstream read interruption")
	for _, raw := range []string{responsesStream(), strings.Split(responsesStream(), "event: response.completed")[0]} {
		s := observe(t, "responses", raw, true, 17, broken)
		if s.ReadEnd != "read_error" || (s.Execution == "completed") != strings.Contains(raw, "event: response.completed") {
			t.Fatal("网络读取结果冒充执行终局", s)
		}
	}
}

func TestModelResultBackpressureAndEarlyClose(t *testing.T) {
	body := &chunkBody{raw: []byte(responsesStream()), step: 1, end: io.EOF}
	var got Snapshot
	calls := 0
	r, _ := New(body, "responses", "text-fixture", "text/event-stream", 200, func(s Snapshot) { got = s; calls++ })
	if body.reads != 0 {
		t.Fatal("预读")
	}
	p := make([]byte, 1)
	_, _ = r.Read(p)
	if body.reads != 1 || len(body.raw) != len(responsesStream())-1 || calls != 0 {
		t.Fatal("观察器自行消费后续字节")
	}
	_ = r.Close()
	if body.reads != 1 || got.FeeReady || got.Execution != "unknown" || got.ReadEnd != "closed" || calls != 1 {
		t.Fatal("提前关闭却排空或结清", got)
	}
}

func TestModelResultBoundedMemoryAndNoTruncation(t *testing.T) {
	for _, content := range []string{strings.Repeat("x", MaxMetadataBytes+1),
		strings.Repeat("data: "+strings.Repeat("x", 1000)+"\n", 1100) + "\n" + responsesStream()} {
		s := observe(t, "responses", content, true, 137, io.EOF)
		if s.FeeReady || s.Execution != "unknown" {
			t.Fatal("超限观察继续收费", s)
		}
	}
	s := observe(t, "responses", strings.Repeat(" ", MaxMetadataBytes)+response, false, 137, io.EOF)
	if s.FeeReady {
		t.Fatal("JSON 超限仍放行")
	}
}

func TestModelResultHeadersAndStatus(t *testing.T) {
	for _, c := range []struct {
		media  string
		status int
	}{{"application/json", 502}, {"application/json", 201}, {"text/plain", 200}, {"text/event-stream; charset=latin1", 200}, {"application/json; extra=yes", 200}} {
		var s Snapshot
		r, _ := New(io.NopCloser(strings.NewReader(response)), "responses", "text-fixture", c.media, c.status, func(got Snapshot) { s = got })
		_, _ = io.ReadAll(r)
		_ = r.Close()
		if s.FeeReady || s.Execution == "completed" {
			t.Fatal("错误 HTTP 身份放行费用", c, s)
		}
	}
}

type closingBody struct {
	closed chan struct{}
	once   sync.Once
}

func (b *closingBody) Read(p []byte) (int, error) { <-b.closed; return 0, io.ErrClosedPipe }
func (b *closingBody) Close() error               { b.once.Do(func() { close(b.closed) }); return nil }

func TestModelResultConcurrentCloseExactlyOnce(t *testing.T) {
	body := &closingBody{closed: make(chan struct{})}
	var s Snapshot
	calls := 0
	r, _ := New(body, "responses", "text-fixture", "text/event-stream", 200, func(got Snapshot) { s = got; calls++ })
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = r.Read(make([]byte, 1)) }()
	go func() { defer wg.Done(); _ = r.Close() }()
	wg.Wait()
	_ = r.Close()
	if calls != 1 || s.FeeReady || s.Execution != "unknown" {
		t.Fatal("并发完成产生重复事实", calls, s)
	}
}
