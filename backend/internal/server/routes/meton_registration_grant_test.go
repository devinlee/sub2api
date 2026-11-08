//go:build meton_managed && grant_integration

package routes

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

// 在本批无网 PostgreSQL 内联验实际注册路由、受限身份复验、服务、仓储及迁移。只注入鉴权后的测试身份。
func TestMetonGrantHTTPPostgres(t *testing.T) {
	raw, err := os.ReadFile(os.Getenv("METON_GRANT_FIXTURE"))
	if err != nil {
		t.Fatal(err)
	}
	var claim service.MetonRegistrationGrant
	if err = json.Unmarshal(raw, &claim); err != nil {
		t.Fatal(err)
	}
	const writeKey = "100000000000000000000003"
	const readKey = "100000000000000000000004"
	for k, v := range map[string]string{"ENVIRONMENT": claim.Environment, "SOURCE": claim.Source, "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": "100000000000000000000001", "READ_KEY_ID": "100000000000000000000002", "GRANT_WRITE_KEY_ID": writeKey, "GRANT_READ_KEY_ID": readKey} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants user=s2_app sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	s := service.NewAdminService(nil, repository.NewUserRepository(nil, db), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
	h := &handler.Handlers{Admin: &handler.AdminHandlers{User: admin.NewUserHandler(s, nil, nil, nil, nil, nil, nil)}}
	engine := gin.New()
	engine.Use(func(c *gin.Context) {
		principals := map[string]adminaccess.Principal{
			"write":       {KeyID: writeKey, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.grants.redeem"}}},
			"read":        {KeyID: readKey, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.grants.inspect"}}},
			"wrong-key":   {KeyID: readKey, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.grants.redeem"}}},
			"wrong-scope": {KeyID: writeKey, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.managed.create"}}},
		}
		if p, ok := principals[c.GetHeader("Test-Principal")]; ok {
			c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), &p))
		}
		c.Next()
	})
	registerUserManagementRoutes(engine.Group("/api/v1/admin"), h)
	srv := httptest.NewServer(engine)
	defer srv.Close()
	path := "/api/v1/admin/meton/managed-accounts/" + claim.Operation.String() + "/grants/" + claim.Eligibility.String()
	do := func(method, relative, principal string, body []byte, keys []string, expected int) []byte {
		t.Helper()
		req, e := http.NewRequest(method, srv.URL+relative, bytes.NewReader(body))
		if e != nil {
			t.Fatal(e)
		}
		req.Header.Set("Test-Principal", principal)
		req.Header.Set("Content-Type", "application/json")
		for _, k := range keys {
			req.Header.Add("Idempotency-Key", k)
		}
		r, e := srv.Client().Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer r.Body.Close()
		b, e := io.ReadAll(r.Body)
		if e != nil || r.StatusCode != expected || r.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("status=%d expected=%d body=%s", r.StatusCode, expected, b)
		}
		return b
	}
	keys := []string{claim.Eligibility.String()}
	do("GET", path, "read", nil, nil, 404)
	for _, p := range []string{"", "read", "wrong-key", "wrong-scope"} {
		do("POST", path, p, raw, keys, 403)
	}
	do("GET", path, "write", nil, nil, 403)
	do("POST", path, "write", raw, nil, 400)
	do("POST", path, "write", raw, append(keys, keys[0]), 400)
	var fields map[string]any
	if err = json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"amount", "remoteUser", "rule"} {
		original := fields[field]
		delete(fields, field)
		invalid, _ := json.Marshal(fields)
		do("POST", path, "write", invalid, keys, 400)
		fields[field] = original
	}
	duplicated := append([]byte("{\"amount\":\"5.00000000\","), bytes.TrimSpace(raw)[1:]...)
	do("POST", path, "write", duplicated, keys, 400)
	do("POST", path+"?retry=1", "write", raw, keys, 400)
	do("GET", path, "read", []byte("ignored"), nil, 400)
	do("POST", path, "write", append(append([]byte{}, raw...), '{', '}'), keys, 400)
	do("POST", path, "write", bytes.Replace(raw, []byte("\"amount\""), []byte("\"Amount\""), 1), keys, 400)
	do("POST", path, "write", bytes.Replace(raw, []byte("5.00000000"), []byte("6.00000000"), 1), keys, 503)
	do("GET", path, "read", nil, nil, 404)
	first := do("POST", path, "write", raw, keys, 200)
	do("POST", path, "write", bytes.Replace(raw, []byte("5.00000000"), []byte("6.00000000"), 1), keys, 409)
	for i := 0; i < 3; i++ {
		if r := do("POST", path, "write", raw, keys, 200); !bytes.Equal(r, first) {
			t.Fatal("changed original receipt")
		}
	}
	if r := do("GET", path, "read", nil, nil, 200); !bytes.Equal(r, first) {
		t.Fatal("lookup returned another receipt")
	}
	do("GET", strings.Replace(path, claim.Operation.String(), uuid.NewString(), 1), "read", nil, nil, 404)
	changed := claim
	changed.SourceMarker = uuid.New()
	wrong, _ := json.Marshal(changed)
	do("POST", path, "write", wrong, keys, 503)
	var envelope struct {
		Code int
		Data service.MetonGrantReceipt
	}
	if json.Unmarshal(first, &envelope) != nil || envelope.Code != 0 || envelope.Data.MetonRegistrationGrant != claim || envelope.Data.Event == uuid.Nil || envelope.Data.NativeCodeID <= 0 {
		t.Fatal("receipt not bound to target")
	}
	if err = os.WriteFile(os.Getenv("METON_GRANT_EXPORT"), first, 0600); err != nil {
		t.Fatal(err)
	}
}
