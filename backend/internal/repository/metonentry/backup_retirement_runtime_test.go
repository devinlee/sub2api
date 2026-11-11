//go:build unit && meton_managed

package metonentry

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

/** 复用已过当前权威 TLS 夹具，仅检查新增部署组合和关闭边界。 */
func backupRuntimeFixture(t *testing.T) (*backupAuthorityFixture, string, backupRetirementRuntimeConfiguration) {
	t.Helper()
	f := newBackupAuthorityFixture(t)
	for name, value := range map[string]string{"ENVIRONMENT": f.config.Environment, "SOURCE": f.config.Source, "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "BACKUP_RETIREMENT_KEY_ID": strings.Repeat("3", 24)} {
		t.Setenv("METON_MANAGED_"+name, value)
	}
	file, _, err := readBackupAuthorityFile(f.path, 16384)
	if err != nil {
		t.Fatal(err)
	}
	cfg := backupRetirementRuntimeConfiguration{1, f.config.Environment, f.config.Source, 1, strings.Repeat("3", 24), 1024, backupAuthorityMaterial{f.path, file.hash}}
	path := filepath.Join(filepath.Dir(f.path), "runtime.json")
	writeBackupRuntime(t, path, cfg)
	return f, path, cfg
}

func writeBackupRuntime(t *testing.T, path string, cfg backupRetirementRuntimeConfiguration) {
	t.Helper()
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestMetonBackupRuntime_CurrentDeploymentAndRetirement(t *testing.T) {
	f, path, cfg := backupRuntimeFixture(t)
	for _, change := range []string{"file", "key", "source", "epoch"} {
		t.Run(change, func(t *testing.T) {
			r, close, err := OpenBackupRetirement(path)
			if err != nil || r == nil {
				t.Fatal(err)
			}
			defer close()
			if r.Backups != nil || r.MaxBytes != 1024 || r.Environment != f.config.Environment {
				t.Fatal("不能创建第二份备份仓储")
			}
			if _, err = r.Authority.Current(context.Background(), "test-personnel-proof", backupAuthorityIntent("inspect")); err != nil {
				t.Fatal(err)
			}
			switch change {
			case "file":
				changed := cfg
				changed.MaxBytes = 2048
				writeBackupRuntime(t, path, changed)
			case "key":
				t.Setenv("METON_MANAGED_BACKUP_RETIREMENT_KEY_ID", strings.Repeat("4", 24))
			case "source":
				t.Setenv("METON_MANAGED_SOURCE", "other")
			case "epoch":
				t.Setenv("METON_MANAGED_EPOCH", "2")
			}
			before := f.calls.Load()
			requireBackupAuthorityRejected(t, r.Authority, backupAuthorityIntent("inspect"))
			writeBackupRuntime(t, path, cfg)
			t.Setenv("METON_MANAGED_BACKUP_RETIREMENT_KEY_ID", cfg.KeyID)
			t.Setenv("METON_MANAGED_SOURCE", cfg.Source)
			t.Setenv("METON_MANAGED_EPOCH", "1")
			requireBackupAuthorityRejected(t, r.Authority, backupAuthorityIntent("inspect"))
			if f.calls.Load() != before {
				t.Fatal("旧部署不能再次发出当前查询")
			}
			fresh, release, err := OpenBackupRetirement(path)
			if err != nil {
				t.Fatal(err)
			}
			defer release()
			if _, err = fresh.Authority.Current(context.Background(), "test-personnel-proof", backupAuthorityIntent("inspect")); err != nil {
				t.Fatal("新装配仍需当前权威确认", err)
			}
			close()
			close()
		})
	}
}

func TestMetonBackupRuntime_ExplicitConfigurationOnly(t *testing.T) {
	_, path, cfg := backupRuntimeFixture(t)
	if r, close, err := OpenBackupRetirement(""); err != nil || r != nil {
		t.Fatal("缺省应关闭")
	} else {
		close()
	}
	for _, change := range []func(*backupRetirementRuntimeConfiguration){
		func(c *backupRetirementRuntimeConfiguration) { c.Source = "other" }, func(c *backupRetirementRuntimeConfiguration) { c.SourceEpoch = 2 },
		func(c *backupRetirementRuntimeConfiguration) { c.KeyID = strings.Repeat("4", 24) }, func(c *backupRetirementRuntimeConfiguration) { c.MaxBytes = 0 },
		func(c *backupRetirementRuntimeConfiguration) { c.MaxBytes = 1 << 41 }, func(c *backupRetirementRuntimeConfiguration) { c.Authority.SHA256 = strings.Repeat("0", 64) },
	} {
		changed := cfg
		change(&changed)
		writeBackupRuntime(t, path, changed)
		if r, close, err := OpenBackupRetirement(path); err == nil || r != nil {
			close()
			t.Fatal("不完整或异域配置不能装配")
		}
	}
	writeBackupRuntime(t, path, cfg)
	t.Setenv("METON_MANAGED_BACKUP_RETIREMENT_KEY_ID", strings.Repeat("2", 24))
	if r, close, err := OpenBackupRetirement(path); err == nil || r != nil {
		close()
		t.Fatal("不能复用另一用途的服务 Key")
	}
}
