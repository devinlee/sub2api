//go:build unit && !meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"testing"
)

/** 普通产物不会读纠正配置，也不会把三种新权限授予已有管理员。 */
func TestCorrectionNativeClosed(t *testing.T) {
	t.Setenv("METON_MANAGED_CORRECTION_CONFIG", "not-a-file")
	v, e := ProvideMetonResultControl(nil)
	if e != nil || v == nil || v.Correction != nil {
		t.Fatal("普通构建启用了受限入口")
	}
	v.Close()
	v.Close()
	p := adminaccess.Policy{GlobalPermissions: []string{"meton.corrections.read", "meton.corrections.approve", "meton.corrections.apply"}}
	for _, action := range []string{"basis", "approve", "apply", "resolution"} {
		if adminaccess.RouteAllowed(p, "POST", "/api/v1/admin"+metonmodel.CorrectionRoute+action) {
			t.Fatal("普通版权限目录放行纠正")
		}
	}
}
