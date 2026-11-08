//go:build meton_managed && model_query_integration

package routes

import (
	"database/sql"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
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

/** 实际 HTTP／原创建／两种受限库身份，测试主体只替代管理鉴权，不替代来源条件事务。 */
func TestMetonOriginalExecutionHTTP(t *testing.T) {
	var fixtures []struct {
		Name      string                         `json:"name"`
		Target    service.MetonRegistrationGrant `json:"target"`
		Caller    string                         `json:"caller"`
		Operation uuid.UUID                      `json:"operation"`
		Expected  json.RawMessage                `json:"expected"`
	}
	raw, err := os.ReadFile(os.Getenv("METON_CONTROL_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 3 {
		t.Fatal("missing fixtures", err)
	}
	readID, cancelID := strings.Repeat("9", 24), strings.Repeat("a", 24)
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "MODEL_READ_KEY_ID": readID, "MODEL_CANCEL_KEY_ID": cancelID} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	connection := func(role string) *sql.DB {
		db, e := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants user="+role+" sslmode=disable")
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { db.Close() })
		return db
	}
	control, err := metonentry.NewOriginalExecutionControl(connection("s2_original_read"), connection("s2_original_cancel"))
	if err != nil {
		t.Fatal(err)
	}
	user := admin.NewUserHandler(nil, nil, nil, nil, nil, nil, nil)
	user.SetMetonModelControl(control)
	r := gin.New()
	r.Use(func(c *gin.Context) {
		p := adminaccess.Principal{KeyID: readID, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.models.inspect"}}}
		switch c.GetHeader("Test-Principal") {
		case "read":
		case "cancel":
			p.KeyID = cancelID
			p.Policy.GlobalPermissions = []string{"meton.models.cancel"}
		case "wrong-key":
			p.KeyID = strings.Repeat("2", 24)
			p.Policy.GlobalPermissions = []string{"meton.models.cancel"}
		default:
			c.Next()
			return
		}
		c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), &p))
		c.Next()
	})
	registerUserManagementRoutes(r.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: user}})
	srv := httptest.NewServer(r)
	defer srv.Close()
	do := func(method, path, principal, body string, status int) json.RawMessage {
		t.Helper()
		q, e := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
		if e != nil {
			t.Fatal(e)
		}
		q.Header.Set("Test-Principal", principal)
		if method == "POST" {
			q.Header.Set("Content-Type", "application/json")
		}
		response, e := srv.Client().Do(q)
		if e != nil {
			t.Fatal(e)
		}
		defer response.Body.Close()
		b, e := io.ReadAll(response.Body)
		if e != nil {
			t.Fatal(e)
		}
		if response.StatusCode != status {
			t.Fatalf("%s: status %d wanted %d", path, response.StatusCode, status)
		}
		if response.Header.Get("Cache-Control") != "no-store" && status != 404 {
			t.Fatal("missing no-store")
		}
		return b
	}
	exports := []map[string]any{}
	for _, f := range fixtures {
		t.Run(f.Name, func(t *testing.T) {
			base := "/api/v1/admin/meton/managed-accounts/" + f.Target.Operation.String() + "/model-calls/" + f.Caller + "/" + f.Operation.String()
			before := do("GET", base+"/execution", "read", "", 200)
			var e struct {
				Data json.RawMessage `json:"data"`
			}
			if json.Unmarshal(before, &e) != nil {
				t.Fatal("bad envelope")
			}
			original, err := metonmodel.ReadExecution(e.Data)
			if err != nil {
				t.Fatal(err)
			}
			expected, err := metonmodel.ReadExecution(f.Expected)
			if err != nil || original.State != expected.State || original.Admission.Origin != expected.Admission.Origin {
				t.Fatal("wrong original state")
			}
			payload := metonmodel.Cancellation{Version: 1, Epoch: 1, Admission: original.Admission}
			encoded, _ := json.Marshal(payload)
			body := string(encoded)
			// 先证明恢复代次或原来源身份变化不会释放 H，再进行本次明确取消。
			for _, field := range []string{"epoch", "accepted_epoch", "source_marker", "source_request_id", "user", "account", "input_digest"} {
				var changed map[string]any
				json.Unmarshal(encoded, &changed)
				admission := changed["admission"].(map[string]any)
				status := 503
				switch field {
				case "epoch":
					changed[field] = 2
					status = 400
				case "accepted_epoch":
					admission[field] = 2
					status = 400
				case "input_digest":
					admission["request"].(map[string]any)[field] = strings.Repeat("b", 64)
				default:
					admission["origin"].(map[string]any)[field] = uuid.NewString()
				}
				bad, _ := json.Marshal(changed)
				do("POST", base+"/cancel", "cancel", string(bad), status)
			}
			do("POST", base+"/cancel", "cancel", strings.Replace(body, `"epoch":1`, `"epoch":1,"epoch":1`, 1), 400)
			do("POST", base+"/cancel", "cancel", "", 400)
			if string(do("GET", base+"/execution", "read", "", 200)) != string(before) {
				t.Fatal("bad context changed original state")
			}
			after := do("POST", base+"/cancel", "cancel", body, 200)
			if json.Unmarshal(after, &e) != nil {
				t.Fatal("bad cancel envelope")
			}
			got, err := metonmodel.ReadExecution(e.Data)
			want := "cancelled_unsent"
			if f.Name == "dispatched" {
				want = "dispatch_claimed"
			}
			if err != nil || got.State != want || got.Admission.Origin != original.Admission.Origin {
				t.Fatal("invalid cancellation receipt", err)
			}
			for i := 0; i < 3; i++ {
				if string(do("GET", base+"/execution", "read", "", 200)) != string(after) || string(do("POST", base+"/cancel", "cancel", body, 200)) != string(after) {
					t.Fatal("replay changed")
				}
			}
			for _, p := range []string{"", "read", "wrong-key"} {
				do("POST", base+"/cancel", p, "", 403)
			}
			do("GET", base+"/execution", "cancel", "", 403)
			do("POST", base+"/cancel?user=other", "cancel", "", 400)
			do("POST", base+"/cancel", "cancel", "{}", 400)
			do("POST", strings.Replace(base, f.Target.Operation.String(), uuid.NewString(), 1)+"/cancel", "cancel", body, 404)
			do("POST", strings.Replace(base, f.Operation.String(), uuid.NewString(), 1)+"/cancel", "cancel", body, 400)
			do("POST", strings.Replace(base, f.Caller, "other", 1)+"/cancel", "cancel", "", 400)
			exports = append(exports, map[string]any{"name": f.Name, "target": f.Target, "caller": f.Caller, "operation": f.Operation, "before": json.RawMessage(before), "after": json.RawMessage(after)})
		})
	}
	base := "/api/v1/admin/meton/managed-accounts/" + fixtures[0].Target.Operation.String() + "/model-calls/" + fixtures[0].Caller + "/" + fixtures[0].Operation.String()
	original, _ := metonmodel.ReadExecution(fixtures[0].Expected)
	encoded, _ := json.Marshal(metonmodel.Cancellation{Version: 1, Epoch: 1, Admission: original.Admission})
	body := string(encoded)
	t.Run("identity-reuse", func(t *testing.T) {
		t.Setenv("METON_MANAGED_MODEL_CANCEL_KEY_ID", readID)
		do("POST", base+"/cancel", "cancel", "", 403)
		do("GET", base+"/execution", "read", "", 403)
	})
	t.Run("missing-control", func(t *testing.T) {
		user.SetMetonModelControl(nil)
		do("POST", base+"/cancel", "cancel", body, 503)
		user.SetMetonModelControl(control)
	})
	t.Run("stale-source", func(t *testing.T) {
		t.Setenv("METON_MANAGED_EPOCH", "2")
		do("POST", base+"/cancel", "cancel", body, 503)
	})
	b, _ := json.Marshal(exports)
	if os.WriteFile(os.Getenv("METON_CONTROL_EXPORT"), b, 0600) != nil {
		t.Fatal("export failed")
	}
}
