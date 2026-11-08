//go:build meton_managed && model_query_integration

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

/** TestMetonModelReadHTTPPostgres 经真实路由和只读数据库身份取原凭证，只注入已鉴权的隔离测试主体。 */
func TestMetonModelReadHTTPPostgres(t *testing.T) {
	var fixtures []struct {
		Target    service.MetonRegistrationGrant `json:"target"`
		Caller    string                         `json:"caller"`
		Operation uuid.UUID                      `json:"operation"`
		Event     uuid.UUID                      `json:"event"`
		Admission json.RawMessage                `json:"admission"`
		Fee       json.RawMessage                `json:"fee"`
	}
	raw, err := os.ReadFile(os.Getenv("METON_MODEL_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 2 {
		t.Fatal("missing original model fixtures", err)
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
	do := func(path, principal, body string, status int) json.RawMessage {
		t.Helper()
		req, err := http.NewRequest("GET", srv.URL+path, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Test-Principal", principal)
		r, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		b, err := io.ReadAll(r.Body)
		if err != nil || r.StatusCode != status || r.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("status=%d expected=%d body=%s", r.StatusCode, status, b)
		}
		return b
	}
	exports := make([]map[string]any, 0, 2)
	for index, f := range fixtures {
		t.Run(f.Caller, func(t *testing.T) {
			path := "/api/v1/admin/meton/managed-accounts/" + f.Target.Operation.String() + "/model-calls/" + f.Caller + "/" + f.Operation.String()
			feePath := path + "/fees/" + f.Event.String()
			for _, route := range []string{path, feePath} {
				for _, p := range []string{"", "wrong-key", "wrong-scope"} {
					do(route, p, "", 403)
				}
				do(route+"?user=other", "read", "", 400)
				do(route+"?", "read", "", 400)
				do(route, "read", "{}", 400)
			}
			admission, fee := do(path, "read", "", 200), do(feePath, "read", "", 200)
			for _, pair := range [][2]json.RawMessage{{admission, f.Admission}, {fee, f.Fee}} {
				var envelope struct {
					Code int             `json:"code"`
					Data json.RawMessage `json:"data"`
				}
				if json.Unmarshal(pair[0], &envelope) != nil || envelope.Code != 0 {
					t.Fatal("invalid envelope")
				}
				var got, want any
				if json.Unmarshal(envelope.Data, &got) != nil || json.Unmarshal(pair[1], &want) != nil {
					t.Fatal("invalid original receipt")
				}
				a, _ := json.Marshal(got)
				b, _ := json.Marshal(want)
				if !bytes.Equal(a, b) {
					t.Fatal("original database receipt changed")
				}
			}
			for i := 0; i < 12; i++ {
				if !bytes.Equal(do(path, "read", "", 200), admission) || !bytes.Equal(do(feePath, "read", "", 200), fee) {
					t.Fatal("original receipt not stable")
				}
			}
			do(strings.Replace(path, f.Operation.String(), uuid.NewString(), 1), "read", "", 404)
			do(path+"/fees/"+fixtures[1-index].Event.String(), "read", "", 404)
			do(strings.Replace(path, f.Target.Operation.String(), uuid.NewString(), 1), "read", "", 404)
			do(strings.Replace(path, f.Caller, "arbitrary.client", 1), "read", "", 400)
			do(strings.Replace(path, f.Operation.String(), strings.ReplaceAll(f.Operation.String(), "-", ""), 1), "read", "", 400)
			exports = append(exports, map[string]any{"target": f.Target, "caller": f.Caller, "operation": f.Operation, "event": f.Event, "admission": admission, "fee": fee})
		})
	}
	for _, suffix := range []string{"CREATE", "READ", "FUNDS_READ", "ISSUE", "INSPECT", "ROTATE", "CLOSE", "GRANT_WRITE", "GRANT_READ"} {
		t.Run("separate-"+suffix, func(t *testing.T) {
			t.Setenv("METON_MANAGED_"+suffix+"_KEY_ID", key)
			s, ok := service.MetonSource()
			_, readable := s.ModelReadID()
			if ok && readable {
				t.Fatal("query role reused another key")
			}
		})
	}
	b, err := json.Marshal(exports)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(os.Getenv("METON_MODEL_EXPORT"), b, 0600); err != nil {
		t.Fatal(err)
	}
}
