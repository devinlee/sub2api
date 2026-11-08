//go:build meton_managed && gift_integration

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
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

/** 只验证本项实际路由、两池权限和原来源事务，不重跑前序账务矩阵。 */
func TestMetonGiftClosureHTTP(t *testing.T) {
	raw, err := os.ReadFile(os.Getenv("METON_GIFT_FIXTURE"))
	var cases []service.MetonGiftRequest
	if err != nil || json.Unmarshal(raw, &cases) != nil || len(cases) != 3 {
		t.Fatal("missing gift fixtures", err)
	}
	readID, writeID := strings.Repeat("b", 24), strings.Repeat("c", 24)
	for k, v := range map[string]string{"ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1", "FUNDS_MODE": "s2-source-v1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "GIFT_READ_KEY_ID": readID, "GIFT_CLOSE_KEY_ID": writeID} {
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
	closure, err := metonentry.NewGiftClosure(connection("s2_gift_read"), connection("s2_gift_close"))
	if err != nil {
		t.Fatal(err)
	}
	user := admin.NewUserHandler(nil, nil, nil, nil, nil, nil, nil)
	user.SetMetonGiftClosure(closure)
	engine := gin.New()
	engine.Use(func(c *gin.Context) {
		var p *adminaccess.Principal
		switch c.GetHeader("Test-Principal") {
		case "read":
			p = &adminaccess.Principal{KeyID: readID, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.gifts.inspect"}}}
		case "write":
			p = &adminaccess.Principal{KeyID: writeID, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.gifts.close"}}}
		case "wrong-key":
			p = &adminaccess.Principal{KeyID: readID, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.gifts.close"}}}
		case "wrong-scope":
			p = &adminaccess.Principal{KeyID: writeID, Policy: adminaccess.Policy{GlobalPermissions: []string{"meton.grants.redeem"}}}
		}
		if p != nil {
			c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), p))
		}
		c.Next()
	})
	registerUserManagementRoutes(engine.Group("/api/v1/admin"), &handler.Handlers{Admin: &handler.AdminHandlers{User: user}})
	srv := httptest.NewServer(engine)
	defer srv.Close()
	encoded := func(q service.MetonGiftRequest) []byte {
		b, e := json.Marshal(q)
		if e != nil {
			t.Fatal(e)
		}
		return b
	}
	path := func(q service.MetonGiftRequest, action string) string {
		return "/api/v1/admin/meton/managed-accounts/" + q.Scope.Operation.String() + "/gift-closure/" + action
	}
	calls := map[string]int{}
	do := func(p, principal string, body []byte, keys []string, want int) json.RawMessage {
		t.Helper()
		r, e := http.NewRequest("POST", srv.URL+p, bytes.NewReader(body))
		if e != nil {
			t.Fatal(e)
		}
		r.Header.Set("Test-Principal", principal)
		r.Header.Set("Content-Type", "application/json")
		for _, key := range keys {
			r.Header.Add("Idempotency-Key", key)
		}
		response, e := srv.Client().Do(r)
		if e != nil {
			t.Fatal(e)
		}
		defer response.Body.Close()
		b, e := io.ReadAll(response.Body)
		if e != nil || response.StatusCode != want || response.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("status=%d want=%d body=%s", response.StatusCode, want, b)
		}
		calls[strings.TrimPrefix(p, "/api/v1/admin/meton/managed-accounts/")] = calls[strings.TrimPrefix(p, "/api/v1/admin/meton/managed-accounts/")] + 1
		return b
	}
	q := cases[0]
	read := q
	read.Final = nil
	keys := []string{q.Final.Decision.String()}
	body := encoded(q)
	before := do(path(q, "inspect"), "read", encoded(read), nil, 200)
	for _, p := range []string{"", "read", "wrong-key", "wrong-scope"} {
		do(path(q, "terminate"), p, body, keys, 403)
	}
	do(path(q, "inspect"), "write", encoded(read), nil, 403)
	do(path(q, "terminate"), "write", body, nil, 400)
	do(path(q, "terminate"), "write", body, append(keys, keys[0]), 400)
	do(path(q, "terminate")+"?retry=1", "write", body, keys, 400)
	do(path(q, "inspect"), "read", encoded(read), keys, 400)
	do(path(q, "inspect"), "read", body, nil, 400)
	do(path(q, "terminate"), "write", append([]byte("{\"final\":null,"), body[1:]...), keys, 400)
	do(path(q, "terminate"), "write", bytes.Replace(body, []byte("\"eligibility\""), []byte("\"Eligibility\""), 1), keys, 400)
	do(path(q, "terminate"), "write", append(append([]byte{}, body...), '{', '}'), keys, 400)
	changed := q
	changed.Scope.User = cases[1].Scope.User
	do(path(q, "terminate"), "write", encoded(changed), keys, 503)
	after := do(path(q, "terminate"), "write", body, keys, 200)
	for _, action := range []string{"terminate", "reconcile"} {
		again := do(path(q, action), "write", body, keys, 200)
		if !bytes.Equal(again, after) {
			t.Fatal("original proof changed", action)
		}
	}
	again := do(path(q, "inspect"), "read", encoded(read), nil, 200)
	if !bytes.Equal(again, after) {
		t.Fatal("original read not same proof")
	}
	final := *q.Final
	final.IdentityEvent = uuid.New()
	changed = q
	changed.Final = &final
	do(path(q, "terminate"), "write", encoded(changed), keys, 409)
	do(path(q, "reconcile"), "write", encoded(changed), keys, 503)
	other := cases[1]
	other.Final = nil
	unaffected := do(path(other, "inspect"), "read", encoded(other), nil, 200)
	pending := do(path(cases[2], "terminate"), "write", encoded(cases[2]), []string{cases[2].Final.Decision.String()}, 200)
	var a, b, c struct {
		Code int
		Data service.MetonGiftReceipt
	}
	if json.Unmarshal(after, &a) != nil || a.Code != 0 || a.Data.Final == nil || *a.Data.Final != *q.Final || a.Data.Retired != "5.00000000" || a.Data.Effects != 1 ||
		json.Unmarshal(unaffected, &b) != nil || b.Data.Final != nil || b.Data.Funds.Balance != "5.00000000" ||
		json.Unmarshal(pending, &c) != nil || c.Data.Final != nil || c.Data.Funds.State != "settlement_pending" || c.Data.Funds.Held != "3.00000000" {
		t.Fatal("gift response scope or funds mismatch")
	}
	user.SetMetonGiftClosure(nil)
	do(path(q, "inspect"), "read", encoded(read), nil, 503)
	result, _ := json.Marshal(map[string]any{"request": q, "pending_request": cases[2], "before": json.RawMessage(before), "after": json.RawMessage(after), "pending": json.RawMessage(pending), "other": json.RawMessage(unaffected), "calls": calls})
	if os.WriteFile(os.Getenv("METON_GIFT_EXPORT"), result, 0600) != nil {
		t.Fatal("export gift evidence")
	}
}
