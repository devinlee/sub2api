//go:build meton_managed && provider_integration && dispatch_integration

package metonentry

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type providerConfigKeys struct{}

func (providerConfigKeys) GetByKey(context.Context, string) (*service.APIKey, error) {
	return nil, service.ErrMetonClosed
}

type providerConfigGroups struct{}

func (providerConfigGroups) GetByID(context.Context, int64) (*service.Group, error) {
	return nil, service.ErrMetonClosed
}

/** 新配置必须使用仅能登记供应绑定的原预占身份，不能靠开关借旧权限静默退化。 */
func TestOriginalProviderConfiguration(t *testing.T) {
	for k, v := range map[string]string{"FUNDS_MODE": "s2-source-v1", "ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "ISSUE_KEY_ID": strings.Repeat("3", 24), "INSPECT_KEY_ID": strings.Repeat("4", 24)} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	signer := dispatchtest.New(t)
	dir := t.TempDir()
	if e := os.WriteFile(filepath.Join(dir, "gateway.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: signer.Certificate.Raw}), 0600); e != nil {
		t.Fatal(e)
	}
	cfg := map[string]any{"format_version": 2, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1, "capture_provider": true, "gateways": map[string]string{"gateway-s2": "gateway.pem"},
		"routes": []any{map[string]any{"group": 1, "profiles": []metonexecution.Spec{{Version: "provider-config-v1", Protocol: "responses", Model: "meton-s2-text-fixture", WireProtocol: "responses", WireModel: "meton-s2-text-fixture", Target: "https://not-contacted.invalid/v1/responses", MaxBodyBytes: 256 * 1024, InputWindow: 2, OutputWindow: 1}}}}}
	for field, role := range map[string]string{"reserve": "s2_provider_reserve", "send": "s2_provider_send", "complete": "s2_provider_complete", "inspect": "s2_provider_inspect"} {
		name := field + ".dsn"
		if e := os.WriteFile(filepath.Join(dir, name), []byte("host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role), 0600); e != nil {
			t.Fatal(e)
		}
		cfg[field+"_dsn_file"] = name
	}
	path := filepath.Join(dir, "provider.json")
	write := func() {
		raw, _ := json.Marshal(cfg)
		if e := os.WriteFile(path, raw, 0600); e != nil {
			t.Fatal(e)
		}
	}
	write()
	a, close, e := Open(path, providerConfigKeys{}, providerConfigGroups{})
	if e != nil || a == nil || !a.captureProvider {
		t.Fatal("新受限装配失败", e)
	}
	close()
	close()
	cfg["capture_provider"] = false
	write()
	if _, close, e = Open(path, providerConfigKeys{}, providerConfigGroups{}); e == nil {
		close()
		t.Fatal("旧模式借用了新绑定权限")
	}
	cfg["capture_provider"] = true
	cfg["reserve_dsn_file"] = "send.dsn"
	write()
	if _, close, e = Open(path, providerConfigKeys{}, providerConfigGroups{}); e == nil {
		close()
		t.Fatal("错误发送身份可伪造预占绑定")
	}
}
