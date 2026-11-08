//go:build meton_managed && dispatch_integration

package metonexecution_test

import (
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"net/http"
	"strings"
	"testing"
)

/** 实际正文、地址、协议和发布窗口共同决定报价；非法输入没有估价后备。 */
func TestModelExecutionProfiles(t *testing.T) {
	spec := metonexecution.Spec{Version: "fixture-window-v1", Protocol: "responses", Model: "meton-s2-text-fixture", WireProtocol: "responses", WireModel: "meton-s2-text-fixture",
		Target: "https://models.invalid/v1/responses", MaxBodyBytes: 4096, InputWindow: 1024, OutputWindow: 128}
	p, err := metonexecution.NewProfile(spec)
	if err != nil {
		t.Fatal(err)
	}
	signer := dispatchtest.New(t)
	original := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic"}`)
	key := []byte("synthetic-key")
	v := signer.Verify(t, dispatchtest.Context(original, key), original, key)
	for _, tc := range []struct {
		name, body string
		ok         bool
	}{
		{"plain", string(original), true},
		{"bound", `{"model":"meton-s2-text-fixture","input":"synthetic","max_output_tokens":4}`, true},
		{"function", `{"model":"meton-s2-text-fixture","input":[{"type":"function_call_output","call_id":"c","output":"ok"}],"tools":[{"type":"function","name":"f","parameters":{"type":"object"}}]}`, true},
		{"duplicate-model", `{"model":"other","model":"meton-s2-text-fixture","input":"x"}`, false},
		{"duplicate-nested", `{"model":"meton-s2-text-fixture","input":[{"role":"user","content":"x","content":"y"}]}`, false},
		{"case-model", `{"Model":"meton-s2-text-fixture","input":"x"}`, false},
		{"over-bound", `{"model":"meton-s2-text-fixture","input":"x","max_output_tokens":129}`, false},
		{"decimal-bound", `{"model":"meton-s2-text-fixture","input":"x","max_output_tokens":2.0}`, false},
		{"wrong-bound", `{"model":"meton-s2-text-fixture","input":"x","max_tokens":2}`, false},
		{"parallel-generation", `{"model":"meton-s2-text-fixture","input":"x","n":2}`, false},
		{"background", `{"model":"meton-s2-text-fixture","input":"x","background":true}`, false},
		{"stored", `{"model":"meton-s2-text-fixture","input":"x","store":true}`, false},
		{"prior-response", `{"model":"meton-s2-text-fixture","input":"x","previous_response_id":"other"}`, false},
		{"media", `{"model":"meton-s2-text-fixture","input":[{"role":"user","content":[{"type":"input_image","image_url":"https://invalid"}]}]}`, false},
		{"server-tool", `{"model":"meton-s2-text-fixture","input":"x","tools":[{"type":"web_search"}]}`, false},
		{"foreign-model", `{"model":"other","input":"x"}`, false},
		{"multiple-roots", string(original) + `{}`, false},
		{"oversize", `{"model":"meton-s2-text-fixture","input":"` + strings.Repeat("x", 4096) + `"}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := http.NewRequest("POST", spec.Target, strings.NewReader(tc.body))
			q, e := p.Quote(v, r, []byte(tc.body))
			if (e == nil) != tc.ok {
				t.Fatalf("quote allowed=%v expected=%v", e == nil, tc.ok)
			}
			if tc.ok {
				record := q.Record()
				if !q.For(v) || record.InputBound != 1024 || record.OutputBound != 128 || record.BodyDigest != dispatchtest.Hash([]byte(tc.body)) {
					t.Fatal("wrong actual execution quote")
				}
				record.InputBound = 1
				if q.Record().InputBound != 1024 {
					t.Fatal("mutable quote")
				}
			}
		})
	}
	for _, edit := range []func(*metonexecution.Spec){func(s *metonexecution.Spec) { s.Target = "http://models.invalid/v1/responses" }, func(s *metonexecution.Spec) { s.Target += "?key=bad" }, func(s *metonexecution.Spec) { s.InputWindow = 0 }, func(s *metonexecution.Spec) { s.OutputWindow = -1 }, func(s *metonexecution.Spec) { s.Version = "*" }, func(s *metonexecution.Spec) { s.Target = "https://user:password@models.invalid/v1/responses" }} {
		changed := spec
		edit(&changed)
		if _, e := metonexecution.NewProfile(changed); e == nil {
			t.Fatal("accepted unsafe published profile")
		}
	}
	r, _ := http.NewRequest("POST", spec.Target, strings.NewReader(string(original)))
	r.Host = "other.invalid"
	if _, e := p.Quote(v, r, original); e == nil {
		t.Fatal("host override accepted")
	}
	var config struct {
		Version int `json:"version"`
	}
	for _, raw := range []string{`{"version":1,"version":2}`, `{"version":1,"unknown":2}`, `{"version":1}{}`, `{"version":1.0}`, `{"Version":1}`} {
		if metonexecution.DecodeStrict([]byte(raw), &config) == nil {
			t.Fatal("ambiguous configuration accepted")
		}
	}
}
