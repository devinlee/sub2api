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

func TestMetonGiftClosureAbsentFromNative(t *testing.T) {
	r := gin.New()
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: &admin.UserHandler{}}})
	for _, action := range []string{"inspect", "terminate", "reconcile"} {
		path := "/api/v1/admin/meton/managed-accounts/a/gift-closure/" + action
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("POST", path, nil))
		if w.Code != 404 {
			t.Fatal("native gift endpoint exists")
		}
		for _, permission := range []string{"meton.gifts.inspect", "meton.gifts.close"} {
			if adminaccess.RouteAllowed(adminaccess.Policy{GlobalPermissions: []string{permission}}, "POST", "/api/v1/admin/meton/managed-accounts/:operation/gift-closure/"+action) {
				t.Fatal("native gift permission exists")
			}
		}
	}
}
