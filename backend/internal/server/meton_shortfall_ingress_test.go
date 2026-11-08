//go:build meton_managed && unit

package server

import (
	"net/http/httptest"
	"os"
	"testing"

	"github.com/gin-gonic/gin"
)

/** 差额只有两条显式 POST；缺省关闭，坏配置不能沿原结果工厂悄悄降级启动。 */
func TestShortfallControlManagedIngress(t *testing.T) {
	t.Setenv("METON_MANAGED_RESULT_CONFIG", "")
	t.Setenv("METON_MANAGED_SHORTFALL_CONFIG", "")
	v, err := ProvideMetonResultControl(nil)
	if err != nil || v == nil || v.Control != nil || v.Shortfall != nil {
		t.Fatal("默认未关闭", err)
	}
	v.Close()
	v.Close()
	path := t.TempDir() + "/invalid.json"
	if err = os.WriteFile(path, []byte(`{"format_version":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("METON_MANAGED_SHORTFALL_CONFIG", path)
	if _, err = ProvideMetonResultControl(nil); err == nil {
		t.Fatal("坏配置未阻断启动")
	}
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(metonManagedIngress())
	for _, action := range []string{"apply", "resolution", "retry"} {
		path := "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall/" + action
		for _, method := range []string{"POST", "GET", "PUT"} {
			r.Handle(method, path, func(c *gin.Context) { c.Status(204) })
		}
		url := "/api/v1/admin/meton/managed-accounts/a/model-calls/meton.chat.v1/b/shortfall/" + action
		for _, method := range []string{"POST", "GET", "PUT"} {
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(method, url, nil))
			want := 403
			if method == "POST" && action != "retry" {
				want = 204
			}
			if w.Code != want {
				t.Fatal(action, method, w.Code)
			}
		}
	}
}
