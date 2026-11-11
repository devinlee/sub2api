//go:build unit && !meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/service"
	"testing"
)

/** 普通构建不读取专用配置、不接受其计划或服务 Key。 */
func TestNativeBackupRetirementConfigurationIgnored(t *testing.T) {
	t.Setenv("METON_MANAGED_BACKUP_RETIREMENT_CONFIG", "not-a-file")
	t.Setenv("METON_MANAGED_BACKUP_RETIREMENT_KEY_ID", "333333333333333333333333")
	value, err := ProvideMetonTextIngress(nil, nil, nil)
	if err != nil || value.BackupRetirement != nil {
		t.Fatal("普通构建取得了托管入口", err)
	}
	value.Close()
	source := service.MetonManagedSource{}
	if _, enabled := source.BackupRetirementKeyID(); enabled {
		t.Fatal("普通构建启用了专用服务 Key")
	}
	if service.ReadBackupRetirementPlan([]byte(`{"format_version":1}`), &service.BackupRetirementPlan{}) == nil {
		t.Fatal("普通构建不应接收托管计划")
	}
}
