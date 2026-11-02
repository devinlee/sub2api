//go:build meton_managed

package admin

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type metonProbeStore struct {
	service.AdminService
	writes, reads int
}

func (p *metonProbeStore) ManagedAccount(ctx context.Context, s service.MetonManagedSource, id uuid.UUID, claim *service.MetonManagedClaim) (*service.MetonManagedReceipt, error) {
	if claim == nil {
		p.reads++
		return nil, nil
	}
	p.writes++
	return &service.MetonManagedReceipt{MetonManagedClaim: *claim, State: "managed", RemoteUser: 1, SourceMarker: uuid.New(), RestrictPublicGroups: true}, nil
}

// 用原 Gin 请求上下文和实际处理器复验：持有者、方法、来源、操作及宽松 JSON 不能替代本人权限。
func TestMetonManagedHandlerDoesNotTrustClientOwnership(t *testing.T) {
	const keyID = "0123456789abcdef01234567"
	const readID = "0123456789abcdef01234569"
	t.Setenv("METON_MANAGED_ENVIRONMENT", "fixture")
	t.Setenv("METON_MANAGED_SOURCE", "managed")
	t.Setenv("METON_MANAGED_EPOCH", "3")
	t.Setenv("METON_MANAGED_CREATE_KEY_ID", keyID)
	t.Setenv("METON_MANAGED_READ_KEY_ID", readID)
	claim := service.MetonManagedClaim{Version: 1, Environment: "fixture", Source: "managed", Epoch: 3, User: uuid.New(), Account: uuid.New(), Operation: uuid.New(), Dispatch: uuid.New()}
	body, _ := json.Marshal(claim)
	base := "/api/v1/admin/meton/managed-accounts"
	op := claim.Operation.String()
	store := &metonProbeStore{}
	h := &UserHandler{adminService: store}
	for _, tc := range []struct {
		name, method, path, body, key, permission, idempotency string
		want                                                   int
	}{
		{"generic_admin", http.MethodPost, base, string(body), "", "", op, 403},
		{"wrong_key", http.MethodPost, base, string(body), "0123456789abcdef01234568", "meton.managed.create", op, 403},
		{"read_only", http.MethodPost, base, string(body), keyID, "meton.managed.read", op, 403},
		{"read_key_given_write_permission", http.MethodPost, base, string(body), readID, "meton.managed.create", op, 403},
		{"write_key_given_read_permission", http.MethodGet, base + "/" + op, "", keyID, "meton.managed.read", "", 403},
		{"wrong_operation", http.MethodPost, base, string(body), keyID, "meton.managed.create", uuid.NewString(), 400},
		{"wrong_epoch", http.MethodPost, base, strings.Replace(string(body), `"epoch":3`, `"epoch":2`, 1), keyID, "meton.managed.create", op, 400},
		{"wrong_source", http.MethodPost, base, strings.Replace(string(body), `"source":"managed"`, `"source":"other"`, 1), keyID, "meton.managed.create", op, 400},
		{"extra_field", http.MethodPost, base, strings.TrimSuffix(string(body), "}") + `,"balance":999}`, keyID, "meton.managed.create", op, 400},
		{"extra_body", http.MethodPost, base, string(body) + "{}", keyID, "meton.managed.create", op, 400},
		{"too_large", http.MethodPost, base, strings.Repeat(" ", 4096) + string(body), keyID, "meton.managed.create", op, 400},
		{"valid_create", http.MethodPost, base, string(body), keyID, "meton.managed.create", op, 200},
		{"query_missing", http.MethodGet, base + "/" + op, "", readID, "meton.managed.read", "", 404},
		{"create_only_read", http.MethodGet, base + "/" + op, "", keyID, "meton.managed.create", "", 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := gin.New()
			r.Use(func(c *gin.Context) {
				if tc.key != "" {
					c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), &adminaccess.Principal{KeyID: tc.key, Policy: adminaccess.Policy{GlobalPermissions: []string{tc.permission}}}))
				}
				c.Next()
			})
			r.POST(base, h.MetonManaged)
			r.GET(base+"/:operation", h.MetonManaged)
			req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			req.Header.Set("Idempotency-Key", tc.idempotency)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)
			if w.Code != tc.want {
				t.Fatalf("status %d, want %d", w.Code, tc.want)
			}
		})
	}
	if store.writes != 1 || store.reads != 1 {
		t.Fatalf("writes %d, reads %d", store.writes, store.reads)
	}
	t.Setenv("METON_MANAGED_READ_KEY_ID", keyID)
	if _, ok := service.MetonSource(); ok {
		t.Fatal("不能给读写两种身份配置同一把密钥")
	}
}
