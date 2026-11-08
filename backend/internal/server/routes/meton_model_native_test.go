//go:build !meton_managed

package routes

import (
	"net/http/httptest"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/gin-gonic/gin"
)

func TestMetonModelReadAbsentFromNativeBuild(t *testing.T) {
	r := gin.New()
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: &admin.UserHandler{}}})
	for _, suffix := range []string{"", "/fees/00000000-0000-4000-8000-000000000003", "/result"} {
		path := "/api/v1/admin/meton/managed-accounts/00000000-0000-4000-8000-000000000001/model-calls/meton.chat.v1/00000000-0000-4000-8000-000000000002" + suffix
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 404 {
			t.Fatal("native build exposed model lookup")
		}
	}
	if adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{"meton.models.inspect"}}, "GET", "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request") {
		t.Fatal("native build exposed model permission")
	}
}
