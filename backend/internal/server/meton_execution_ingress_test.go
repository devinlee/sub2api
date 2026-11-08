package server

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"testing"
)

/** 新入口逐方法放行；不能沿取消路径扩大成原生修改余额权限。 */
func TestMetonOriginalExecutionIngress(t *testing.T) {
	for _, suffix := range []string{"execution", "cancel"} {
		for _, method := range []string{"GET", "POST", "PUT", "PATCH", "DELETE"} {
			r := gin.New()
			r.Use(metonManagedIngress())
			r.Handle(method, "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/"+suffix, func(c *gin.Context) { c.Status(204) })
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(method, "/api/v1/admin/meton/managed-accounts/a/model-calls/b/c/"+suffix, nil))
			want := 403
			if suffix == "execution" && method == "GET" || suffix == "cancel" && method == "POST" {
				want = 204
			}
			if w.Code != want {
				t.Fatalf("%s %s: %d", method, suffix, w.Code)
			}
		}
	}
}
