//go:build meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/gin-gonic/gin"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 逐条检查原生 HTTP 入口即使已注册、有下游处理器，也不会进入支付、供应模型、后台重试或运维写入。
func TestMetonGrantIngressFamilies(t *testing.T) {
	for _, entry := range []string{
		"POST /api/v1/auth/register", "POST /api/v1/auth/oauth/pending/create-account", "POST /api/v1/admin/users",
		"POST /api/v1/admin/users/1/auth-identities", "POST /api/v1/redeem", "POST /api/v1/admin/redeem-codes/create-and-redeem",
		"POST /api/v1/admin/promo-codes", "POST /api/v1/user/aff/transfer", "POST /api/v1/payment/orders", "POST /api/v1/payment/orders/verify",
		"POST /api/v1/payment/public/orders/verify", "POST /api/v1/payment/public/orders/resolve", "POST /api/v1/payment/orders/1/cancel",
		"POST /api/v1/admin/payment/orders/1/retry", "POST /api/v1/payment/orders/1/refund-request",
		"POST /api/v1/admin/payment/orders/1/refund", "POST /api/v1/admin/payment/orders/1/refund/query",
		"GET /api/v1/payment/webhook/easypay", "POST /api/v1/payment/webhook/easypay", "POST /api/v1/payment/webhook/alipay", "POST /api/v1/payment/webhook/wxpay",
		"POST /api/v1/payment/webhook/stripe", "POST /api/v1/payment/webhook/airwallex",
		"POST /api/v1/admin/users/1/balance", "POST /api/v1/admin/subscriptions/1/restore", "POST /v1/chat/completions", "POST /v1/responses",
		"POST /v1/images/generations", "POST /v1/images/edits", "POST /v1/audio/speech", "POST /v1/audio/transcriptions",
		"DELETE /api/v1/admin/users/1", "DELETE /api/v1/admin/redeem-codes/1", "POST /api/v1/admin/backups/1/restore",
	} {
		t.Run(entry, func(t *testing.T) {
			method, path, _ := strings.Cut(entry, " ")
			r := gin.New()
			r.Use(metonManagedIngress())
			reached := false
			r.Handle(method, path, func(c *gin.Context) { reached = true; c.Status(200) })
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(method, path, nil))
			if w.Code != 403 || reached {
				t.Fatal("native effect reachable")
			}
		})
	}
}

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
		{"GET", "/api/v1/admin/meton/managed-accounts/:operation/funds", 200},
		{"POST", "/api/v1/payment/orders", 403}, {"POST", "/api/v1/payment/orders/12/refund", 403},
		{"POST", "/api/v1/redeem", 403}, {"POST", "/api/v1/promo-codes/redeem", 403}, {"POST", "/v1/responses", 403},
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
