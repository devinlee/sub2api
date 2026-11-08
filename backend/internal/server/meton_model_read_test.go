package server

import (
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestMetonModelReadIngress(t *testing.T) {
	r := gin.New()
	r.Use(metonManagedIngress())
	path := "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request"
	called := 0
	for _, suffix := range []string{"", "/fees/:event"} {
		r.Any(path+suffix, func(c *gin.Context) { called++; c.Status(204) })
	}
	base := "/api/v1/admin/meton/managed-accounts/a/model-calls/meton.chat.v1/b"
	for _, suffix := range []string{"", "/fees/c"} {
		for _, method := range []string{"GET", "POST", "PUT", "PATCH", "DELETE"} {
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(method, base+suffix, nil))
			want := 403
			if method == "GET" {
				want = 204
			}
			if w.Code != want {
				t.Fatalf("%s status=%d", method, w.Code)
			}
		}
	}
	if called != 2 {
		t.Fatal("non-query method reached handler")
	}
}
