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

func TestMetonGrantAbsentFromNativeBuild(t *testing.T) {
	r := gin.New()
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: &admin.UserHandler{}}})
	for method, perm := range map[string]string{"GET": "meton.grants.inspect", "POST": "meton.grants.redeem"} {
		path := "/api/v1/admin/meton/managed-accounts/00000000-0000-4000-8000-000000000001/grants/00000000-0000-4000-8000-000000000002"
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(method, path, nil))
		if w.Code != 404 || adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{perm}}, method, "/api/v1/admin/meton/managed-accounts/:operation/grants/:eligibility") {
			t.Fatal("managed grant exposed by native build")
		}
	}
}
