//go:build !meton_managed && unit

package routes

import (
	"net/http/httptest"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/gin-gonic/gin"
)

/** 普通构建没有差额路由和权限，不能从管理员登录继承来源写入能力。 */
func TestShortfallControlNativeRoutes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{}})
	for _, action := range []string{"apply", "resolution"} {
		path := "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall/" + action
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/admin/meton/managed-accounts/a/model-calls/meton.chat.v1/b/shortfall/"+action, nil))
		if w.Code != 404 || adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{"meton.shortfalls.apply", "meton.shortfalls.read"}}, "POST", path) {
			t.Fatal("普通构建开放资金接缝", action, w.Code)
		}
	}
}
