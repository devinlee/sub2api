package server

import (
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/gin-gonic/gin"
	"net/http"
	"strings"
)

// 专用候选从 Gin 已匹配的方法和路由逐项放行；注册/OAuth、用户 Key、余额、模型以及路径别名均无默认许可。
func metonManagedIngress(modelEnabled ...bool) gin.HandlerFunc {
	ok := map[string]bool{
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall-restoration/approve":    true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall-restoration/apply":      true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall-restoration/resolution": true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall-restoration/original":   true,
		"GET /api/v1/admin" + metonmodel.FinancialRoute:                                                                      true,
		"POST /api/v1/admin" + metonmodel.CorrectionRoute + "basis":                                                          true,
		"POST /api/v1/admin" + metonmodel.CorrectionRoute + "approve":                                                        true,
		"POST /api/v1/admin" + metonmodel.CorrectionRoute + "apply":                                                          true,
		"POST /api/v1/admin" + metonmodel.CorrectionRoute + "resolution":                                                     true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall/apply":                  true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall/resolution":             true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/observe":           true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/proof":             true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/apply":             true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/resolution":        true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/statements/open":                                               true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/statements/page":                                               true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/gift-closure/inspect":                                          true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/gift-restoration/inspect":                                      true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/gift-restoration/reconcile":                                    true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/gift-restoration/terminate":                                    true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/gift-closure/terminate":                                        true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/gift-closure/reconcile":                                        true,
		"GET /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/execution":                         true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/cancel":                           true,
		"GET /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/result":                            true,
		"GET /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request":                                   true,
		"GET /api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/fees/:event":                       true,
		"POST /api/v1/admin/meton/managed-accounts/:operation/grants/:eligibility":                                           true,
		"GET /api/v1/admin/meton/managed-accounts/:operation/grants/:eligibility":                                            true,
		"GET /api/v1/admin/meton/managed-accounts/:operation/funds":                                                          true,
		"POST /api/v1/admin/meton/session-closures/:operation":                                                               true, "GET /api/v1/admin/meton/session-closures/:operation": true,
		"GET /api/v1/admin/meton/session-closures/:operation/keys/:binding": true,
		"GET /api/v1/admin/meton/managed-keys/:operation/retirement":        true, "POST /api/v1/admin/meton/managed-keys/:operation/retirement": true,
		"GET /health": true, "GET /api/v1/settings/public": true, "POST /api/v1/auth/login": true, "POST /api/v1/auth/login/2fa": true,
		"GET /api/v1/auth/me": true, "POST /api/v1/auth/refresh": true, "POST /api/v1/auth/logout": true,
		"GET /api/v1/admin/compliance": true, "POST /api/v1/admin/compliance/accept": true,
		"GET /api/v1/admin/settings/admin-api-keys": true, "POST /api/v1/admin/settings/admin-api-keys": true,
		"DELETE /api/v1/admin/settings/admin-api-keys/:id": true,
		"POST /api/v1/admin/meton/managed-accounts":        true, "GET /api/v1/admin/meton/managed-accounts/:operation": true,
		"POST /api/v1/admin/meton/managed-keys": true, "GET /api/v1/admin/meton/managed-keys/:operation": true,
	}
	return func(c *gin.Context) {
		route := c.FullPath()
		if len(modelEnabled) == 1 && modelEnabled[0] && c.Request.Method == http.MethodPost &&
			(route == "/v1/responses" || route == "/v1/chat/completions") && c.Request.URL.Path == route && c.Request.URL.RawPath == "" && c.Request.URL.RawQuery == "" && !c.Request.URL.ForceQuery {
			c.Next()
			return
		}
		if ok[c.Request.Method+" "+route] {
			c.Next()
			return
		}
		// 无后端匹配的静态页面仅供管理员前端加载；API 未匹配时不能借 SPA 的 200 响应伪装成功。
		path := c.Request.URL.Path
		if route == "" && c.Request.Method == http.MethodGet && (path == "/" || strings.HasPrefix(path, "/assets/") || strings.HasPrefix(path, "/admin/") || path == "/login" || path == "/favicon.ico") {
			c.Next()
			return
		}
		c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"code": "METON_SOURCE_RESTRICTED"})
	}
}
