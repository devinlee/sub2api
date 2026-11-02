//go:build meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/gin-gonic/gin"
	"net/http"
	"net/http/httptest"
	"testing"
)

// 从实际 Gin 组合验证完整方法/路由的默认拒绝；不能绕过原管理鉴权或承诺检查。
func TestMetonManagedIngressDoesNotExposeNativeWrites(t *testing.T) {
	r := gin.New()
	r.Use(metonManagedIngress())
	paths := []struct {
		verb, route string
		want        int
	}{
		{"POST", "/api/v1/admin/meton/managed-accounts", 200}, {"GET", "/api/v1/admin/compliance", 200},
		{"POST", "/api/v1/auth/register", 403}, {"POST", "/api/v1/auth/oauth/google/create-account", 403}, {"POST", "/api/v1/keys", 403},
		{"POST", "/api/v1/admin/users", 403}, {"POST", "/api/v1/admin/users/11/balance", 403}, {"POST", "/v1/chat/completions", 403},
		{"GET", "/api/v1/admin/users", 403}, {"POST", "/api/v1/admin/meton/managed-accounts/alias", 403},
	}
	for _, p := range paths {
		r.Handle(p.verb, p.route, func(c *gin.Context) { c.String(200, "ok") })
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(p.verb, p.route, nil))
		if w.Code != p.want {
			t.Fatalf("%s %s status %d", p.verb, p.route, w.Code)
		}
	}
	read := adminaccess.Policy{GlobalPermissions: []string{"meton.managed.read"}}
	if !adminaccess.RouteAllowed(read, http.MethodGet, "/api/v1/admin/meton/managed-accounts/:operation") ||
		adminaccess.RouteAllowed(read, http.MethodPost, "/api/v1/admin/meton/managed-accounts") {
		t.Fatal("托管读写权限混用")
	}
}
