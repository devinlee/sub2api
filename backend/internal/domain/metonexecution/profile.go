//go:build meton_managed

// Package metonexecution 把已发布执行窗口绑定到真正出站的文本规格，不推测 token 数。
package metonexecution

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
)

var ErrExecution = errors.New("published text execution unavailable")
var identifier = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,120}$`)
var modelName = regexp.MustCompile(`^[A-Za-z0-9_./:-]{1,160}$`)

// Spec 只由部署装配。两个上界必须来自已核实的模型硬执行窗口，不能填写本机估算值。
type Spec struct {
	Version      string `json:"version"`
	Protocol     string `json:"protocol"`
	Model        string `json:"model"`
	WireProtocol string `json:"wire_protocol"`
	WireModel    string `json:"wire_model"`
	Target       string `json:"target"`
	MaxBodyBytes int    `json:"max_body_bytes"`
	InputWindow  int    `json:"input_window"`
	OutputWindow int    `json:"output_window"`
}

type Profile struct {
	spec Spec
	hash string
}

/** Spec 返回值副本，供来源入口选取原模型和固定调度组；修改它不会改变已装配报价。 */
func (p *Profile) Spec() Spec {
	if p == nil {
		return Spec{}
	}
	return p.spec
}

/** ValidateOriginal 复验网关签名中的原模型和文本范围，原生转换后的正文仍须单独 Quote。 */
func (p *Profile) ValidateOriginal(body []byte) error {
	if p == nil || len(body) == 0 || len(body) > 256*1024 {
		return ErrExecution
	}
	return validateText(body, p.spec.Protocol, p.spec.Model, p.spec.OutputWindow)
}

/** DecodeStrict 同时拒绝未知字段与重复键，用于部署规格文件，不能静默覆盖前一个配置值。 */
func DecodeStrict(raw []byte, destination any) error {
	if len(raw) == 0 || len(raw) > 1024*1024 || !utf8.Valid(raw) {
		return ErrExecution
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	original, err := readJSON(d, 0)
	if err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return ErrExecution
	}
	d = json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(destination) != nil {
		return ErrExecution
	}
	// encoding/json 会接受结构字段的大小写别名。按解码后的正式键形复核，不能让别名绕过配置检查。
	canonical, err := json.Marshal(destination)
	if err != nil {
		return ErrExecution
	}
	var decoded any
	if json.Unmarshal(canonical, &decoded) != nil || !sameKeys(original, decoded) {
		return ErrExecution
	}
	return nil
}

func sameKeys(original, decoded any) bool {
	switch actual := original.(type) {
	case map[string]any:
		expected, ok := decoded.(map[string]any)
		if !ok {
			return false
		}
		for key, value := range actual {
			other, found := expected[key]
			if !found || !sameKeys(value, other) {
				return false
			}
		}
	case []any:
		expected, ok := decoded.([]any)
		if !ok || len(actual) != len(expected) {
			return false
		}
		for i, value := range actual {
			if !sameKeys(value, expected[i]) {
				return false
			}
		}
	}
	return true
}

/** NewProfile 复制并固定规格；真实部署只接受精确 HTTPS 目标，无通配符或自动降级。 */
func NewProfile(s Spec) (*Profile, error) { return newProfile(s, false) }

func newProfile(s Spec, fixture bool) (*Profile, error) {
	u, err := url.Parse(s.Target)
	if err != nil || u.User != nil || u.Host == "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.RawPath != "" ||
		(u.Scheme != "https" && !(fixture && u.Scheme == "http" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"))) ||
		!identifier.MatchString(s.Version) || !modelName.MatchString(s.Model) || !modelName.MatchString(s.WireModel) ||
		!protocol(s.Protocol) || !protocol(s.WireProtocol) || s.MaxBodyBytes < 1 || s.MaxBodyBytes > 1024*1024 ||
		s.InputWindow < 1 || s.InputWindow > 100000000 || s.OutputWindow < 1 || s.OutputWindow > 100000000 {
		return nil, ErrExecution
	}
	if (s.WireProtocol == "responses" && !strings.HasSuffix(u.Path, "/responses")) ||
		(s.WireProtocol == "chat_completions" && !strings.HasSuffix(u.Path, "/chat/completions")) {
		return nil, ErrExecution
	}
	raw, _ := json.Marshal(s)
	return &Profile{spec: s, hash: hash(raw)}, nil
}

func protocol(p string) bool { return p == "responses" || p == "chat_completions" }
func hash(b []byte) string   { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// Record 不含模型正文、密钥或目标地址；实际内容与部署规格只保留摘要。
type Record struct {
	Version      int    `json:"version"`
	Profile      string `json:"profile"`
	ProfileHash  string `json:"profile_hash"`
	WireProtocol string `json:"wire_protocol"`
	WireModel    string `json:"wire_model"`
	TargetHash   string `json:"target_hash"`
	BodyDigest   string `json:"body_digest"`
	InputBound   int    `json:"input_bound"`
	OutputBound  int    `json:"output_bound"`
}

// Quote 只能由已固定的 Profile 生成，不暴露可写的已验结果。
type Quote struct {
	record     Record
	originHash string
}

func (q *Quote) Record() Record {
	if q == nil {
		return Record{}
	}
	return q.record
}
func (q *Quote) For(v *metondispatch.Verified) bool {
	return q != nil && v != nil && q.originHash == v.Hash() && q.record.Version == 1
}

/** Quote 在原生转换以后核对实际请求；用完整执行窗口保守预占，金额仍由来源库的固定价格计算。 */
func (p *Profile) Quote(v *metondispatch.Verified, r *http.Request, body []byte) (*Quote, error) {
	if p == nil || v == nil || v.Hash() == "" || r == nil || r.URL == nil || r.Method != "POST" || r.URL.String() != p.spec.Target ||
		r.ContentLength != int64(len(body)) || len(body) == 0 || len(body) > p.spec.MaxBodyBytes ||
		v.Context().Protocol != p.spec.Protocol || v.Context().Model != p.spec.Model || r.Header.Get("Content-Encoding") != "" ||
		(r.Host != "" && r.Host != r.URL.Host) {
		return nil, ErrExecution
	}
	if err := validateText(body, p.spec.WireProtocol, p.spec.WireModel, p.spec.OutputWindow); err != nil {
		return nil, err
	}
	return &Quote{originHash: v.Hash(), record: Record{Version: 1, Profile: p.spec.Version, ProfileHash: p.hash,
		WireProtocol: p.spec.WireProtocol, WireModel: p.spec.WireModel, TargetHash: hash([]byte(p.spec.Target)), BodyDigest: hash(body),
		InputBound: p.spec.InputWindow, OutputBound: p.spec.OutputWindow}}, nil
}

/** readJSON 不允许重复键、多个根对象和过深数据，避免各层解析出不同模型或执行参数。 */
func readJSON(d *json.Decoder, depth int) (any, error) {
	if depth > 32 {
		return nil, ErrExecution
	}
	t, err := d.Token()
	if err != nil {
		return nil, ErrExecution
	}
	if delim, ok := t.(json.Delim); ok {
		switch delim {
		case '{':
			m := map[string]any{}
			for d.More() {
				k, e := d.Token()
				if e != nil {
					return nil, ErrExecution
				}
				key, ok := k.(string)
				if !ok {
					return nil, ErrExecution
				}
				if _, seen := m[key]; seen {
					return nil, ErrExecution
				}
				value, e := readJSON(d, depth+1)
				if e != nil {
					return nil, e
				}
				m[key] = value
			}
			end, e := d.Token()
			if e != nil || end != json.Delim('}') {
				return nil, ErrExecution
			}
			return m, nil
		case '[':
			a := []any{}
			for d.More() {
				v, e := readJSON(d, depth+1)
				if e != nil {
					return nil, e
				}
				a = append(a, v)
			}
			end, e := d.Token()
			if e != nil || end != json.Delim(']') {
				return nil, ErrExecution
			}
			return a, nil
		default:
			return nil, ErrExecution
		}
	}
	return t, nil
}

func only(m map[string]any, names string) bool {
	allowed := strings.Fields(names)
	for k := range m {
		found := false
		for _, name := range allowed {
			if k == name {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
func integer(v any, low, high int) bool {
	n, ok := v.(json.Number)
	if !ok {
		return false
	}
	i, e := n.Int64()
	return e == nil && i >= int64(low) && i <= int64(high)
}

func validateText(body []byte, proto, model string, maximum int) error {
	if !utf8.Valid(body) {
		return ErrExecution
	}
	d := json.NewDecoder(bytes.NewReader(body))
	d.UseNumber()
	value, e := readJSON(d, 0)
	if e != nil {
		return e
	}
	if _, e = d.Token(); e != io.EOF {
		return ErrExecution
	}
	m, ok := value.(map[string]any)
	if !ok || m["model"] != model || !only(m, "model input messages instructions stream stream_options temperature top_p max_output_tokens max_completion_tokens max_tokens stop seed frequency_penalty presence_penalty tools tool_choice parallel_tool_calls reasoning text response_format n store prompt_cache_key include") {
		return ErrExecution
	}
	if v, present := m["n"]; present && !integer(v, 1, 1) {
		return ErrExecution
	}
	if v, present := m["store"]; present && v != false {
		return ErrExecution
	}
	for _, k := range []string{"stream", "parallel_tool_calls"} {
		if v, yes := m[k]; yes {
			if _, ok := v.(bool); !ok {
				return ErrExecution
			}
		}
	}
	for _, k := range []string{"max_output_tokens", "max_completion_tokens", "max_tokens"} {
		if v, yes := m[k]; yes {
			if !integer(v, 1, maximum) || (proto == "responses" && k != "max_output_tokens") || (proto == "chat_completions" && k == "max_output_tokens") {
				return ErrExecution
			}
		}
	}
	if v, yes := m["include"]; yes {
		a, ok := v.([]any)
		if !ok {
			return ErrExecution
		}
		for _, item := range a {
			if item != "reasoning.encrypted_content" {
				return ErrExecution
			}
		}
	}
	if v, yes := m["tools"]; yes {
		tools, ok := v.([]any)
		if !ok {
			return ErrExecution
		}
		for _, value := range tools {
			tool, ok := value.(map[string]any)
			if !ok || tool["type"] != "function" {
				return ErrExecution
			}
		}
	}
	if proto == "responses" {
		if _, bad := m["messages"]; bad {
			return ErrExecution
		}
		if !responseInput(m["input"]) {
			return ErrExecution
		}
	} else {
		if _, bad := m["input"]; bad {
			return ErrExecution
		}
		if !messages(m["messages"], false) {
			return ErrExecution
		}
	}
	return nil
}

func textContent(value any, responses bool) bool {
	if _, ok := value.(string); ok {
		return true
	}
	a, ok := value.([]any)
	if !ok {
		return false
	}
	for _, v := range a {
		part, ok := v.(map[string]any)
		if !ok || !only(part, "type text annotations") {
			return false
		}
		kind, ok := part["type"].(string)
		if !ok || (!responses && kind != "text") || (responses && kind != "input_text" && kind != "output_text") {
			return false
		}
		if _, ok := part["text"].(string); !ok {
			return false
		}
	}
	return true
}
func messages(value any, responses bool) bool {
	a, ok := value.([]any)
	if !ok || len(a) == 0 {
		return false
	}
	for _, v := range a {
		m, ok := v.(map[string]any)
		if !ok || !only(m, "type role content name tool_calls tool_call_id id status") {
			return false
		}
		role, _ := m["role"].(string)
		if role != "user" && role != "assistant" && role != "system" && role != "developer" && (!responses && role != "tool" || responses) {
			return false
		}
		if content, yes := m["content"]; yes && content != nil && !textContent(content, responses) {
			return false
		}
		if value, yes := m["tool_calls"]; yes {
			calls, ok := value.([]any)
			if !ok {
				return false
			}
			for _, v := range calls {
				call, ok := v.(map[string]any)
				if !ok || call["type"] != "function" {
					return false
				}
			}
		}
	}
	return true
}
func responseInput(value any) bool {
	if _, ok := value.(string); ok {
		return true
	}
	a, ok := value.([]any)
	if !ok || len(a) == 0 {
		return false
	}
	for _, v := range a {
		m, ok := v.(map[string]any)
		if !ok {
			return false
		}
		kind, _ := m["type"].(string)
		switch kind {
		case "", "message":
			if !messages([]any{v}, true) {
				return false
			}
		case "function_call":
			if !only(m, "type id call_id name arguments status") {
				return false
			}
			if _, ok := m["arguments"].(string); !ok {
				return false
			}
		case "function_call_output":
			if !only(m, "type id call_id output status") {
				return false
			}
			if _, ok := m["output"].(string); !ok {
				return false
			}
		case "reasoning":
			if !only(m, "type id summary encrypted_content status") {
				return false
			}
		default:
			return false
		}
	}
	return true
}
