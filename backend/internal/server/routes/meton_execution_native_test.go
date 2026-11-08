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

/** 普通构建不提供这次新增的来源控制路由或取消权限。 */
func TestMetonOriginalExecutionAbsentFromNative(t *testing.T) {
	r := gin.New()
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: &admin.UserHandler{}}})
	for _, x := range []struct{ method, suffix, permission string }{{"GET", "execution", "meton.models.inspect"}, {"POST", "cancel", "meton.models.cancel"}} {
		path := "/api/v1/admin/meton/managed-accounts/a/model-calls/meton.chat.v1/b/" + x.suffix
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(x.method, path, nil))
		if w.Code != 404 {
			t.Fatal("native route exposed")
		}
		route := "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/" + x.suffix
		if adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{x.permission}}, x.method, route) {
			t.Fatal("native permission exposed")
		}
	}
}
