//go:build meton_managed && model_query_integration

package metonentry

import (
	"context"
	"database/sql"
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

type controlNoModels struct{}

func (controlNoModels) GetByKey(context.Context, string) (*service.APIKey, error) {
	return nil, service.ErrMetonClosed
}
func (controlNoModels) GetByID(context.Context, int64) (*service.Group, error) {
	return nil, service.ErrMetonClosed
}

/** 只验新增两池配置和权限差异，不重跑旧模型准入／四池故障矩阵。 */
func TestMetonOriginalExecutionConfiguration(t *testing.T) {
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "ISSUE_KEY_ID": strings.Repeat("3", 24), "INSPECT_KEY_ID": strings.Repeat("4", 24),
		"MODEL_READ_KEY_ID": strings.Repeat("9", 24), "MODEL_CANCEL_KEY_ID": strings.Repeat("a", 24)} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	dir := t.TempDir()
	signer := dispatchtest.New(t)
	if os.WriteFile(filepath.Join(dir, "gateway.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: signer.Certificate.Raw}), 0600) != nil {
		t.Fatal("write certificate")
	}
	for _, role := range []string{"s2_execution_reserve", "s2_execution_send", "s2_execution_complete", "s2_execution_result_read", "s2_original_read", "s2_original_cancel"} {
		if os.WriteFile(filepath.Join(dir, role+".dsn"), []byte("host=127.0.0.1 dbname=s2_grants user="+role+" sslmode=disable"), 0600) != nil {
			t.Fatal("write role config")
		}
	}
	cfg := map[string]any{"format_version": 2, "environment": "s2-isolated", "source": "s2-managed", "epoch": 1,
		"gateways": map[string]string{"gateway-s2": "gateway.pem"}, "reserve_dsn_file": "s2_execution_reserve.dsn", "send_dsn_file": "s2_execution_send.dsn",
		"complete_dsn_file": "s2_execution_complete.dsn", "inspect_dsn_file": "s2_execution_result_read.dsn",
		"routes": []any{map[string]any{"group": 1, "profiles": []metonexecution.Spec{{Version: "fixture-window-v1", Protocol: "responses", Model: "meton-s2-text-fixture",
			WireProtocol: "responses", WireModel: "meton-s2-text-fixture", Target: "https://not-contacted.invalid/v1/responses", MaxBodyBytes: 256 * 1024, InputWindow: 1024, OutputWindow: 128}}}}}
	open := func(want bool, control bool) {
		t.Helper()
		raw, _ := json.Marshal(cfg)
		path := filepath.Join(dir, "config.json")
		if os.WriteFile(path, raw, 0600) != nil {
			t.Fatal("write config")
		}
		result, close, err := Open(path, controlNoModels{}, controlNoModels{})
		defer close()
		if want {
			if err != nil || result == nil || (result.Control != nil) != control {
				t.Fatal("configuration rejected", err)
			}
		} else if err == nil {
			t.Fatal("unsafe configuration accepted")
		}
	}
	open(true, false)
	cfg["execution_read_dsn_file"] = "s2_original_read.dsn"
	open(false, false)
	cfg["execution_cancel_dsn_file"] = "s2_original_cancel.dsn"
	open(true, true)
	for _, field := range []string{"execution_read_dsn_file", "execution_cancel_dsn_file"} {
		keep := cfg[field]
		for _, bad := range []any{"s2_execution_send.dsn", "s2_original_read.dsn", "missing.dsn", nil} {
			if bad == keep {
				continue
			}
			cfg[field] = bad
			open(false, false)
		}
		cfg[field] = keep
	}
	t.Run("reused-key", func(t *testing.T) {
		t.Setenv("METON_MANAGED_MODEL_CANCEL_KEY_ID", strings.Repeat("9", 24))
		open(false, false)
	})
	db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants user=postgres sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.Exec("GRANT EXECUTE ON FUNCTION " + ExecutionReadFunction + " TO s2_original_cancel"); err != nil {
		t.Fatal(err)
	}
	defer db.Exec("REVOKE EXECUTE ON FUNCTION " + ExecutionReadFunction + " FROM s2_original_cancel")
	open(false, false)
}
