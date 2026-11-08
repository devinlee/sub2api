//go:build meton_managed && statement_integration

package routes

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/handler"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

/** 本项通过实际 Gin、受限 PostgreSQL 和真实来源函数，仅测试新查询接缝。 */
func TestMetonStatementHTTP(t *testing.T) {
	raw, err := os.ReadFile(os.Getenv("METON_STATEMENT_FIXTURE"))
	var fixtures []service.MetonStatementRequest
	if err != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 3 {
		t.Fatal("missing statement fixtures", err)
	}
	id := strings.Repeat("d", 24)
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1", "CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "STATEMENT_READ_KEY_ID": id} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	db, err := sql.Open("postgres", "host=127.0.0.1 dbname=s2_grants user=s2_statement sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	query, err := metonentry.NewStatements(db)
	if err != nil {
		t.Fatal(err)
	}
	user := admin.NewUserHandler(nil, nil, nil, nil, nil, nil, nil)
	user.SetMetonStatements(query)
	engine := gin.New()
	engine.Use(func(c *gin.Context) {
		key := id
		permission := "meton.statements.read"
		switch c.GetHeader("Test-Principal") {
		case "read":
		case "wrong-key":
			key = strings.Repeat("e", 24)
		case "wrong-permission":
			permission = "meton.grants.redeem"
		default:
			c.Next()
			return
		}
		c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), &adminaccess.Principal{KeyID: key, Policy: adminaccess.Policy{GlobalPermissions: []string{permission}}}))
		c.Next()
	})
	registerUserManagementRoutes(engine.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: user}})
	encode := func(q service.MetonStatementRequest) []byte {
		v, e := json.Marshal(q)
		if e != nil {
			t.Fatal(e)
		}
		return v
	}
	path := func(q service.MetonStatementRequest, part string) string {
		return "/api/v1/admin/meton/managed-accounts/" + q.Scope.Operation.String() + "/statements/" + part
	}
	call := func(p, principal string, body []byte, want int, headers map[string]string) json.RawMessage {
		t.Helper()
		r := httptest.NewRequest("POST", p, bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Test-Principal", principal)
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		engine.ServeHTTP(w, r)
		if w.Code != want || w.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("status=%d want=%d body=%s", w.Code, want, w.Body.String())
		}
		return append([]byte(nil), w.Body.Bytes()...)
	}
	q := fixtures[0]
	opening := call(path(q, "open"), "read", encode(q), 200, nil)
	var head struct {
		Data struct {
			Cut struct {
				Sequence int64
				Event    *uuid.UUID
			}
			Funds struct{ Balance string }
		}
	}
	if json.Unmarshal(opening, &head) != nil || head.Data.Cut.Sequence != 2 || head.Data.Funds.Balance != "8.00000000" {
		t.Fatal("source opening mismatch")
	}
	paged := q
	paged.Page = &service.MetonStatementCursor{Sequence: head.Data.Cut.Sequence, Event: head.Data.Cut.Event, Size: 1}
	first := call(path(q, "page"), "read", encode(paged), 200, nil)
	var page struct {
		Data struct {
			Last  int64
			Count int
			More  bool
			Items []json.RawMessage
		}
	}
	if json.Unmarshal(first, &page) != nil || page.Data.Count != 1 || !page.Data.More || len(page.Data.Items) != 1 {
		t.Fatal("first page mismatch")
	}
	next := paged
	cursor := *paged.Page
	next.Page = &cursor
	next.Page.After = page.Data.Last
	second := call(path(q, "page"), "read", encode(next), 200, nil)
	if json.Unmarshal(second, &page) != nil || page.Data.Count != 1 || page.Data.More {
		t.Fatal("last page mismatch")
	}
	for _, principal := range []string{"", "wrong-key", "wrong-permission"} {
		call(path(q, "open"), principal, encode(q), 403, nil)
	}
	call(path(q, "open")+"?unused=1", "read", encode(q), 400, nil)
	call(path(q, "open"), "read", encode(q), 400, map[string]string{"Idempotency-Key": uuid.NewString()})
	call(path(q, "open"), "read", encode(q), 400, map[string]string{"Content-Encoding": "gzip"})
	call(path(q, "open"), "read", []byte(strings.TrimSuffix(string(encode(q)), "}")+`,"from":"2000-01-01"}`), 400, nil)
	call(path(q, "open"), "read", []byte(strings.TrimSuffix(string(encode(q)), "}")+`,"other":true}`), 400, nil)
	call(path(q, "open"), "read", encode(paged), 400, nil)
	call(path(q, "page"), "read", encode(q), 400, nil)
	wrong := q
	wrong.Scope.User = fixtures[1].Scope.User
	call(path(q, "open"), "read", encode(wrong), 503, nil)
	wrong = q
	wrong.Scope.Epoch++
	call(path(q, "open"), "read", encode(wrong), 400, nil)
	other := fixtures[1]
	other.Page = paged.Page
	call(path(other, "page"), "read", encode(other), 503, nil)
	oversized := paged
	bad := *paged.Page
	oversized.Page = &bad
	oversized.Page.Size = 101
	call(path(q, "page"), "read", encode(oversized), 400, nil)
	empty := call(path(fixtures[2], "open"), "read", encode(fixtures[2]), 200, nil)
	t.Setenv("METON_MANAGED_STATEMENT_READ_KEY_ID", strings.Repeat("1", 24))
	call(path(q, "open"), "read", encode(q), 403, nil)
	t.Setenv("METON_MANAGED_STATEMENT_READ_KEY_ID", id)
	user.SetMetonStatements(nil)
	call(path(q, "open"), "read", encode(q), 503, nil)
	wire, e := json.Marshal(map[string]any{"format_version": 1, "request": q, "header": opening, "first": first, "last": second, "empty_request": fixtures[2], "empty": empty})
	if e != nil || os.WriteFile(os.Getenv("METON_STATEMENT_EXPORT"), wire, 0600) != nil {
		t.Fatal("cannot save narrow receipts")
	}
	// 查询权限不能借给写入；此处复用原权限目录，不重新执行资金写入矩阵。
	policy := adminaccess.Policy{GlobalPermissions: []string{"meton.statements.read"}}
	for _, p := range []string{"/meton/managed-accounts", "/meton/managed-keys", "/meton/managed-accounts/:operation/grants/:eligibility", "/meton/managed-accounts/:operation/gift-closure/terminate"} {
		if adminaccess.RouteAllowed(policy, http.MethodPost, p) {
			t.Fatal("statement permission reaches writer")
		}
	}
}
