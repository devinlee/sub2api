package server

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"strings"
)

// 专用候选从 Gin 已匹配的方法和路由逐项放行；注册/OAuth、用户 Key、余额、模型以及路径别名均无默认许可。
func metonManagedIngress() gin.HandlerFunc {
	ok := map[string]bool{
		"GET /api/v1/admin/meton/managed-keys/:operation/retirement": true, "POST /api/v1/admin/meton/managed-keys/:operation/retirement": true,
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
