//go:build !meton_managed

package routes

import (
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"testing"
)

/** 普通构建不登记托管账单路由或权限。 */
func TestMetonStatementAbsentFromNative(t *testing.T) {
	r := gin.New()
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: &admin.UserHandler{}}})
	for _, action := range []string{"open", "page"} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/admin/meton/managed-accounts/a/statements/"+action, nil))
		if w.Code != 404 || adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{"meton.statements.read"}}, "POST", "/api/v1/admin/meton/managed-accounts/:operation/statements/"+action) {
			t.Fatal("native statement exposed")
		}
	}
}
