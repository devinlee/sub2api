//go:build unit && meton_managed

package server

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/gin-gonic/gin"
)

/** 验真实托管工厂默认关闭、坏配置拒启，并核对全局入口对动作和方法的限制。 */
func TestCorrectionManagedIngress(t *testing.T) {
	t.Setenv("METON_MANAGED_RESULT_CONFIG", "")
	t.Setenv("METON_MANAGED_SHORTFALL_CONFIG", "")
	t.Setenv("METON_MANAGED_CORRECTION_CONFIG", "")
	v, err := ProvideMetonResultControl(nil)
	if err != nil || v == nil || v.Correction != nil {
		t.Fatal("默认意外开放纠正")
	}
	v.Close()
	v.Close()
	path := filepath.Join(t.TempDir(), "bad.json")
	if os.WriteFile(path, []byte(`{"format_version":1}`), 0600) != nil {
		t.Fatal("配置夹具失败")
	}
	t.Setenv("METON_MANAGED_CORRECTION_CONFIG", path)
	if _, err = ProvideMetonResultControl(nil); err == nil {
		t.Fatal("坏配置退回原工厂")
	}
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(metonManagedIngress())
	for _, a := range []string{"basis", "approve", "apply", "resolution", "retry"} {
		for _, m := range []string{"POST", "GET"} {
			p := "/api/v1/admin" + metonmodel.CorrectionRoute + a
			r.Handle(m, p, func(c *gin.Context) { c.Status(204) })
			path := strings.NewReplacer(":operation", "a", ":caller", "meton.chat.v1", ":request", "b").Replace(p)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(m, path, nil))
			want := 403
			if m == "POST" && a != "retry" {
				want = 204
			}
			if w.Code != want {
				t.Fatalf("%s %s %d", a, m, w.Code)
			}
		}
	}
}
