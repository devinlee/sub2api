//go:build unit && meton_managed

package server

import (
	"net/http/httptest"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

/** 只增加四个完整方法／路径；普通删除、原地恢复和伪造的备用用途保持关闭。 */
func TestMetonBackupRetirementIngress_ExactRoutesAndConfiguration(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, entry := range []struct {
		method, path string
		status       int
	}{
		{"POST", service.BackupRetirementRoute + "inspect", 204}, {"POST", service.BackupRetirementRoute + "execute", 204},
		{"POST", service.BackupRetirementRoute + "reconcile", 204}, {"POST", service.BackupRetirementRoute + "resume", 204},
		{"GET", service.BackupRetirementRoute + "execute", 403}, {"POST", service.BackupRetirementRoute + "delete", 403},
		{"DELETE", "/backups/id", 403}, {"POST", "/backups/id/restore", 403},
	} {
		path := "/api/v1/admin" + entry.path
		r := gin.New()
		r.Use(metonManagedIngress())
		r.Handle(entry.method, path, func(c *gin.Context) { c.Status(204) })
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(entry.method, path, nil))
		if w.Code != entry.status {
			t.Fatal(entry, w.Code)
		}
	}
	t.Setenv("METON_MANAGED_BACKUP_RETIREMENT_CONFIG", "")
	value, err := ProvideMetonTextIngress(nil, nil, nil)
	if err != nil || value.BackupRetirement != nil {
		t.Fatal("缺配置必须关闭", err)
	}
	value.Close()
	value.Close()
	t.Setenv("METON_MANAGED_BACKUP_RETIREMENT_CONFIG", "not-a-file")
	if value, err = ProvideMetonTextIngress(nil, nil, nil); err == nil {
		value.Close()
		t.Fatal("显式错误配置不能忽略")
	}
}
