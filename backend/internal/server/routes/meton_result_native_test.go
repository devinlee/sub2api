//go:build !meton_managed && unit

package routes

import (
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"testing"
)

/** 普通构建无新路径及权限目录，不因环境变量或管理员权限放开来源结算。 */
func TestResultControlNativeBuild(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{}})
	for _, action := range []string{"observe", "proof", "apply", "resolution"} {
		path := "/meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/" + action
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/admin/meton/managed-accounts/a/model-calls/meton.chat.v1/b/reconciliation/"+action, nil))
		if w.Code != 404 || adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{"meton.results.observe", "meton.results.read", "meton.results.apply"}}, "POST", "/api/v1/admin"+path) {
			t.Fatal("普通构建开放了恢复接缝", action, w.Code)
		}
	}
}
