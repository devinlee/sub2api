package server

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"testing"
)

func TestMetonGiftClosureIngress(t *testing.T) {
	for _, action := range []string{"inspect", "terminate", "reconcile"} {
		for _, method := range []string{"POST", "GET", "PUT", "PATCH", "DELETE"} {
			r := gin.New()
			r.Use(metonManagedIngress())
			r.Handle(method, "/api/v1/admin/meton/managed-accounts/:operation/gift-closure/"+action, func(c *gin.Context) { c.Status(204) })
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(method, "/api/v1/admin/meton/managed-accounts/a/gift-closure/"+action, nil))
			want := 403
			if method == "POST" {
				want = 204
			}
			if w.Code != want {
				t.Fatal(method, action, w.Code)
			}
		}
	}
}
