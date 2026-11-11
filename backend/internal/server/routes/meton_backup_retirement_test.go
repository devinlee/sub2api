//go:build unit && meton_managed

package routes

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type backupRouteSettings struct {
	service.SettingRepository
	mu     sync.Mutex
	values map[string]string
}

func (s *backupRouteSettings) GetValue(_ context.Context, key string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	value, exists := s.values[key]
	if !exists {
		return "", service.ErrSettingNotFound
	}
	return value, nil
}
func (s *backupRouteSettings) SetMultiple(_ context.Context, values map[string]string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, v := range values {
		s.values[k] = v
	}
	return nil
}

type backupRouteSecrets struct{}

func (backupRouteSecrets) Encrypt(value string) (string, error) { return value, nil }
func (backupRouteSecrets) Decrypt(value string) (string, error) { return value, nil }

type backupRouteObjects struct {
	service.BackupObjectStore
	mu      sync.Mutex
	bytes   map[string]string
	holds   map[string]bool
	deletes int
}

func (s *backupRouteObjects) CurrentVersion(_ context.Context, key string) (service.BackupObjectVersion, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return service.BackupObjectVersion{Key: key, VersionID: "version-1", Size: int64(len(s.bytes[key]))}, nil
}
func (s *backupRouteObjects) ReadVersion(_ context.Context, v service.BackupObjectVersion) (io.ReadCloser, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return io.NopCloser(strings.NewReader(s.bytes[v.Key])), nil
}
func (s *backupRouteObjects) VersionExists(_ context.Context, v service.BackupObjectVersion) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, exists := s.bytes[v.Key]
	return exists && v.VersionID == "version-1", nil
}
func (s *backupRouteObjects) ProtectVersion(_ context.Context, v service.BackupObjectVersion) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.holds[v.Key] = true
	return nil
}
func (s *backupRouteObjects) VersionProtected(_ context.Context, v service.BackupObjectVersion) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.holds[v.Key], nil
}
func (s *backupRouteObjects) DeleteVersion(_ context.Context, v service.BackupObjectVersion) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.holds[v.Key] || v.VersionID != "version-1" {
		return errors.New("protected")
	}
	delete(s.bytes, v.Key)
	s.deletes++
	if s.deletes == 1 {
		return io.ErrUnexpectedEOF
	}
	return nil
}
func (s *backupRouteObjects) count() int { s.mu.Lock(); defer s.mu.Unlock(); return s.deletes }

type backupRoutePeople struct{ until time.Time }

func (p backupRoutePeople) Current(_ context.Context, assertion string, i service.BackupRetentionIntent) (service.BackupRetentionOperator, error) {
	if i.Purpose != "cash.backup.retirement."+assertion+".v1" {
		return service.BackupRetentionOperator{}, service.ErrBackupRetirementUnavailable
	}
	return service.BackupRetentionOperator{Environment: i.Environment, Source: i.Source, Person: "22222222-2222-4222-8222-222222222222", Generation: 1, Version: 1, Until: p.until}, nil
}

/** 实际原路由／处理器／协调相接；本组只模拟仓储和对象，不代替后续实库、SDK 与两个 Host 组合。 */
func TestMetonBackupRetirementHTTP_OriginalOperationsAndUnknown(t *testing.T) {
	gin.SetMode(gin.TestMode)
	const key = "333333333333333333333333"
	for name, value := range map[string]string{"ENVIRONMENT": "fixture", "SOURCE": "source", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "BACKUP_RETIREMENT_KEY_ID": key} {
		t.Setenv("METON_MANAGED_"+name, value)
	}
	records := []service.BackupRecord{
		{ID: "target", Status: "completed", SizeBytes: 8, Parts: []service.BackupPart{{Index: 1, S3Key: "target-a", SizeBytes: 4}, {Index: 2, S3Key: "target-b", SizeBytes: 4}}},
		{ID: "keeper", Status: "completed", SizeBytes: 8, S3Key: "keeper"}, {ID: "other", Status: "completed", SizeBytes: 5, S3Key: "other"},
	}
	raw, _ := json.Marshal(records)
	settings := &backupRouteSettings{values: map[string]string{"backup_records": string(raw),
		"backup_s3_config": `{"bucket":"isolated-fixture","access_key_id":"fixture","secret_access_key":"fixture"}`}}
	objects := &backupRouteObjects{bytes: map[string]string{"target-a": "orig", "target-b": "inal", "keeper": "original", "other": "other"}, holds: map[string]bool{}}
	backups := service.NewBackupService(settings, &config.Config{}, backupRouteSecrets{}, func(context.Context, *service.BackupS3Config) (service.BackupObjectStore, error) { return objects, nil }, nil)
	defer backups.Stop()
	h := admin.NewBackupHandler(backups, nil, nil)
	setup := &service.ManagedBackupRetirement{Environment: "fixture", Source: "source", MaxBytes: 1024, Authority: backupRoutePeople{time.Now().Add(time.Minute)}}
	h.SetMetonBackupRetirement(setup)
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if c.GetHeader("Test-Key") != "ordinary" {
			permission := "meton.backup_retirement." + c.GetHeader("Test-Permission")
			id := key
			if c.GetHeader("Test-Key") == "other" {
				id = strings.Repeat("4", 24)
			}
			p := &adminaccess.Principal{KeyID: id, Policy: adminaccess.Policy{GlobalPermissions: []string{permission}}}
			c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), p))
		}
		c.Next()
	})
	registerBackupRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{Backup: h}}, nil)
	host := httptest.NewServer(r)
	defer host.Close()
	call := func(action, permission, principal, proof, suffix string, p service.BackupRetirementPlan, status int) json.RawMessage {
		t.Helper()
		raw, _ := json.Marshal(p)
		req, _ := http.NewRequest("POST", host.URL+"/api/v1/admin"+service.BackupRetirementRoute+action+suffix, strings.NewReader(string(raw)))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Test-Key", principal)
		req.Header.Set("Test-Permission", permission)
		if proof != "" {
			req.Header.Set("X-Meton-Operator-Assertion", proof)
		}
		reply, err := host.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer reply.Body.Close()
		body, _ := io.ReadAll(reply.Body)
		if reply.StatusCode != status || reply.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("%s 状态不符: %d %s", action, reply.StatusCode, body)
		}
		if strings.Contains(string(body), "test-personnel-proof") {
			t.Fatal("响应不能回显证明")
		}
		if status == 200 {
			var envelope struct {
				Data json.RawMessage `json:"data"`
			}
			if json.Unmarshal(body, &envelope) != nil {
				t.Fatal("响应无效")
			}
			return envelope.Data
		}
		return body
	}
	base := service.BackupRetirementPlan{Format: 1, Operation: uuid.NewString(), Environment: "fixture", Source: "source", Target: "target", Keeper: "keeper"}
	call("inspect", "inspect", "ordinary", "inspect", "", base, 403)
	call("inspect", "inspect", "other", "inspect", "", base, 403)
	call("inspect", "execute", "service", "inspect", "", base, 403)
	call("inspect", "inspect", "service", "", "", base, 400)
	call("inspect", "inspect", "service", "inspect", "?other=1", base, 400)
	wrong := base
	wrong.Source = "other"
	call("inspect", "inspect", "service", "inspect", "", wrong, 400)
	wrong = base
	wrong.Generation = 1
	call("inspect", "inspect", "service", "inspect", "", wrong, 400)
	var plan service.BackupRetirementPlan
	if err := json.Unmarshal(call("inspect", "inspect", "service", "inspect", "", base, 200), &plan); err != nil {
		t.Fatal(err)
	}
	if plan.Generation != 1 || plan.Content == "" || len(plan.TargetObjects) != 2 || objects.count() != 0 {
		t.Fatal("检查不能执行清理")
	}
	call("execute", "inspect", "service", "execute", "", plan, 403)
	call("execute", "execute", "service", "inspect", "", plan, 503)
	failed := call("execute", "execute", "service", "execute", "", plan, 503)
	if !strings.Contains(string(failed), `"state":"unknown"`) || objects.count() != 1 {
		t.Fatal("派发应答丢失必须未知")
	}
	for _, action := range []string{"execute", "reconcile"} {
		var receipt service.BackupRetirementReceipt
		if err := json.Unmarshal(call(action, action, "service", action, "", plan, 200), &receipt); err != nil || receipt.State != "unknown" || objects.count() != 1 {
			t.Fatal("重入只能查询原操作")
		}
	}
	var complete service.BackupRetirementReceipt
	if err := json.Unmarshal(call("resume", "resume", "service", "resume", "", plan, 200), &complete); err != nil || complete.State != "completed" || objects.count() != 2 {
		t.Fatal("明确续作须沿原计划完成剩余版本")
	}
	call("execute", "execute", "service", "execute", "", plan, 200)
	if objects.count() != 2 {
		t.Fatal("完成后不能重删")
	}
	value, _ := settings.GetValue(context.Background(), "backup_records")
	var final []service.BackupRecord
	_ = json.Unmarshal([]byte(value), &final)
	if len(final) != 3 || final[0].Status != "retired" || !final[1].MetonRetentionPinned || final[2].Status != "completed" {
		t.Fatal("原记录或其他备份改变")
	}
}
