//go:build meton_managed && model_query_integration

package routes

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

/** 终局查询走真实 HTTP、服务和受限库；查询次数不改变原资金或制造模型请求。 */
func TestMetonModelResultHTTPPostgres(t *testing.T) {
	var fixtures []struct {
		Name      string                         `json:"name"`
		Target    service.MetonRegistrationGrant `json:"target"`
		Caller    string                         `json:"caller"`
		Operation uuid.UUID                      `json:"operation"`
		Expected  json.RawMessage                `json:"expected"`
	}
	raw, err := os.ReadFile(os.Getenv("METON_RESULT_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 6 {
		t.Fatal("missing result fixtures", err)
	}
	const key = "100000000000000000000009"
	for name, value := range map[string]string{"ENVIRONMENT": fixtures[0].Target.Environment, "SOURCE": fixtures[0].Target.Source, "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": "100000000000000000000001", "READ_KEY_ID": "100000000000000000000002", "MODEL_READ_KEY_ID": key} {
		t.Setenv("METON_MANAGED_"+name, value)
	}
	db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants user=s2_model_read sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	s := service.NewAdminService(nil, repository.NewUserRepository(nil, db), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
	h := &handler.Handlers{Admin: &handler.AdminHandlers{User: admin.NewUserHandler(s, nil, nil, nil, nil, nil, nil)}}
	router := gin.New()
	router.Use(func(c *gin.Context) {
		p := adminaccess.Principal{KeyID: key, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.models.inspect"}}}
		switch c.GetHeader("Test-Principal") {
		case "read":
		case "wrong-key":
			p.KeyID = "100000000000000000000002"
		case "wrong-scope":
			p.Policy.GlobalPermissions = []string{"meton.managed.read"}
		default:
			c.Next()
			return
		}
		c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), &p))
		c.Next()
	})
	registerUserManagementRoutes(router.Group("/api/v1/admin"), h)
	srv := httptest.NewServer(router)
	defer srv.Close()
	do := func(method, path, principal, body string, status int) json.RawMessage {
		t.Helper()
		req, err := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Test-Principal", principal)
		r, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		raw, _ := io.ReadAll(r.Body)
		if r.StatusCode != status {
			t.Fatalf("status=%d expected=%d", r.StatusCode, status)
		}
		if status == 200 && r.Header.Get("Cache-Control") != "no-store" {
			t.Fatal("missing no-store")
		}
		return raw
	}
	exports := []map[string]any{}
	for _, f := range fixtures {
		t.Run(f.Name, func(t *testing.T) {
			path := "/api/v1/admin/meton/managed-accounts/" + f.Target.Operation.String() + "/model-calls/" + f.Caller + "/" + f.Operation.String() + "/result"
			raw := do("GET", path, "read", "", 200)
			var envelope struct {
				Data json.RawMessage `json:"data"`
			}
			if json.Unmarshal(raw, &envelope) != nil {
				t.Fatal("invalid envelope")
			}
			parsed, err := metonmodel.ReadResult(envelope.Data)
			if err != nil {
				t.Fatal(err)
			}
			got, _ := json.Marshal(parsed)
			want, err := metonmodel.ReadResult(f.Expected)
			if err != nil {
				t.Fatal(err)
			}
			wanted, _ := json.Marshal(want)
			if !bytes.Equal(got, wanted) {
				t.Fatal("original result changed")
			}
			for i := 0; i < 8; i++ {
				if !bytes.Equal(do("GET", path, "read", "", 200), raw) {
					t.Fatal("result replay changed")
				}
			}
			for _, principal := range []string{"", "wrong-key", "wrong-scope"} {
				do("GET", path, principal, "", 403)
			}
			do("GET", path+"?account=other", "read", "", 400)
			do("GET", path, "read", "{}", 400)
			do("POST", path, "read", "", 404)
			do("GET", strings.Replace(path, f.Target.Operation.String(), uuid.NewString(), 1), "read", "", 404)
			do("GET", strings.Replace(path, f.Operation.String(), uuid.NewString(), 1), "read", "", 404)
			do("GET", strings.Replace(path, f.Caller, "arbitrary.client", 1), "read", "", 400)
			do("GET", strings.Replace(path, f.Operation.String(), strings.ReplaceAll(f.Operation.String(), "-", ""), 1), "read", "", 400)
			exports = append(exports, map[string]any{"name": f.Name, "target": f.Target, "caller": f.Caller, "operation": f.Operation, "response": json.RawMessage(raw)})
		})
	}
	t.Run("role-reuse", func(t *testing.T) {
		t.Setenv("METON_MANAGED_READ_KEY_ID", key)
		f := fixtures[0]
		path := "/api/v1/admin/meton/managed-accounts/" + f.Target.Operation.String() + "/model-calls/" + f.Caller + "/" + f.Operation.String() + "/result"
		do("GET", path, "read", "", 403)
	})
	t.Run("stale-source", func(t *testing.T) {
		t.Setenv("METON_MANAGED_EPOCH", "2")
		f := fixtures[0]
		path := "/api/v1/admin/meton/managed-accounts/" + f.Target.Operation.String() + "/model-calls/" + f.Caller + "/" + f.Operation.String() + "/result"
		do("GET", path, "read", "", 404)
	})
	encoded, _ := json.Marshal(exports)
	if os.WriteFile(os.Getenv("METON_RESULT_EXPORT"), encoded, 0600) != nil {
		t.Fatal("export failed")
	}
}
