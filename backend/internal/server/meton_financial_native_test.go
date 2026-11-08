//go:build unit && !meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"testing"
)

/** 普通产物不读取观察配置，不登记托管财务权限。 */
func TestFinancialNativeClosed(t *testing.T) {
	t.Setenv("METON_MANAGED_FINANCIAL_CONFIG", "not-a-file")
	v, err := ProvideMetonResultControl(nil)
	if err != nil || v == nil || v.Financial != nil {
		t.Fatal("普通构建启用财务观察")
	}
	v.Close()
	v.Close()
	if adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{metonmodel.FinancialPermission}}, "GET", "/api/v1/admin"+metonmodel.FinancialRoute) {
		t.Fatal("普通权限目录放行")
	}
}
