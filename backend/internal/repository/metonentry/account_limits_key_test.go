//go:build meton_managed && dispatch_integration && account_limits_integration

package metonentry_test

import (
	"context"
	"math"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type limitKeyReader struct {
	key   *service.APIKey
	reads int
}

func (r *limitKeyReader) GetByKey(context.Context, string) (*service.APIKey, error) {
	r.reads++
	return r.key, nil
}

type limitGroupReader struct{ reads int }

func (r *limitGroupReader) GetByID(context.Context, int64) (*service.Group, error) {
	r.reads++
	return &service.Group{ID: 1, Status: service.StatusActive, Platform: service.PlatformOpenAI}, nil
}

/** 在真实签名和实际准入入口核对错误 Key 配置；读取替身不执行数据库或上游请求。 */
func TestAccountKeyLimitConfigurationAdmission(t *testing.T) {
	signer := dispatchtest.New(t)
	profile, err := metonexecution.NewProfile(metonexecution.Spec{Version: "fixture-window-v1", Protocol: "responses", Model: "meton-s2-text-fixture",
		WireProtocol: "responses", WireModel: "meton-s2-text-fixture", Target: "https://models.invalid/v1/responses", MaxBodyBytes: 4096, InputWindow: 1024, OutputWindow: 128})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		change func(*service.APIKey)
	}{
		{"supported", func(k *service.APIKey) {}},
		{"quota", func(k *service.APIKey) { k.Quota = 1 }},
		{"old-quota-usage", func(k *service.APIKey) { k.QuotaUsed = 1 }},
		{"window-5h", func(k *service.APIKey) { k.RateLimit5h = 1 }},
		{"window-1d", func(k *service.APIKey) { k.RateLimit1d = 1 }},
		{"window-7d", func(k *service.APIKey) { k.RateLimit7d = 1 }},
		{"old-window-5h", func(k *service.APIKey) { k.Usage5h = 1 }},
		{"old-window-1d", func(k *service.APIKey) { k.Usage1d = 1 }},
		{"old-window-7d", func(k *service.APIKey) { k.Usage7d = 1 }},
		{"negative-limit", func(k *service.APIKey) { k.Quota = -1 }},
		{"invalid-limit", func(k *service.APIKey) { k.RateLimit1d = math.NaN() }},
		{"manual-source-key", func(k *service.APIKey) {}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			key := &service.APIKey{ID: 1, UserID: 1, Key: "synthetic-key", Status: service.StatusActive,
				User: &service.User{ID: 1, Status: service.StatusActive, Concurrency: 2}}
			tc.change(key)
			keys, groups := &limitKeyReader{key: key}, &limitGroupReader{}
			entry, e := metonentry.New(signer.Verifier, keys, groups, &metonledger.TextLedger{}, &metonledger.TextLedger{}, &metonledger.TextLedger{}, &metonledger.TextLedger{},
				[]metonentry.Route{{Group: 1, Profiles: []*metonexecution.Profile{profile}}})
			if e != nil {
				t.Fatal(e)
			}
			body := `{"model":"meton-s2-text-fixture","input":"synthetic"}`
			c := dispatchtest.Context([]byte(body), []byte(key.Key))
			header, proof := signer.Encode(t, c, "/v1/responses", time.Now())
			r := httptest.NewRequest("POST", "https://source.invalid/v1/responses", strings.NewReader(body))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+key.Key)
			if tc.name != "manual-source-key" {
				r.Header.Set(metondispatch.ContextHeader, header)
				r.Header.Set(metondispatch.ProofHeader, proof)
			}
			accepted, actual, e := entry.Admit(r)
			if tc.name == "supported" {
				if e != nil || accepted == nil || actual == nil || groups.reads != 1 || keys.reads != 1 {
					t.Fatal("supported key configuration refused", e)
				}
				accepted.Body.Close()
			} else {
				if e == nil || accepted != nil || actual != nil || groups.reads != 0 {
					t.Fatal("unsupported configuration reached scheduling", e)
				}
				if tc.name == "manual-source-key" && keys.reads != 0 {
					t.Fatal("missing gateway proof reached key lookup")
				}
			}
		})
	}
}
