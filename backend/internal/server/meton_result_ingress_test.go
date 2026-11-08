//go:build meton_managed && unit

package server

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"os"
	"testing"
)

/** 新路由只放行四个已登记方法；默认缺配置不装配控制权限。 */
func TestResultControlManagedIngress(t *testing.T) {
	t.Setenv("METON_MANAGED_RESULT_CONFIG", "")
	value, err := ProvideMetonResultControl(nil)
	if err != nil || value == nil || value.Control != nil {
		t.Fatal("默认未关闭", err)
	}
	value.Close()
	value.Close()
	path := t.TempDir() + "/invalid.json"
	if err := os.WriteFile(path, []byte(`{"format_version":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("METON_MANAGED_RESULT_CONFIG", path)
	if _, err := ProvideMetonResultControl(nil); err == nil {
		t.Fatal("残缺配置没有阻断启动")
	}
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(metonManagedIngress())
	for _, action := range []string{"observe", "proof", "apply", "resolution"} {
		path := "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/" + action
		for _, method := range []string{"POST", "GET"} {
			r.Handle(method, path, func(c *gin.Context) { c.Status(204) })
		}
		url := "/api/v1/admin/meton/managed-accounts/a/model-calls/meton.chat.v1/b/reconciliation/" + action
		for _, method := range []string{"POST", "GET"} {
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(method, url, nil))
			want := 204
			if method == "GET" {
				want = 403
			}
			if w.Code != want {
				t.Fatal(action, method, w.Code)
			}
		}
	}
}
