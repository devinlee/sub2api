//go:build meton_managed

package admin

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type fundsProbe struct {
	service.AdminService
	calls int
}

func (p *fundsProbe) ManagedFunds(context.Context, service.MetonManagedSource, uuid.UUID) (*service.MetonFundsReceipt, error) {
	p.calls++
	return nil, nil
}

func TestMetonManagedFundsHandler(t *testing.T) {
	create, read, funds := strings.Repeat("1", 24), strings.Repeat("2", 24), strings.Repeat("3", 24)
	t.Setenv("METON_MANAGED_ENVIRONMENT", "fixture")
	t.Setenv("METON_MANAGED_SOURCE", "source")
	t.Setenv("METON_MANAGED_EPOCH", "2")
	t.Setenv("METON_MANAGED_CREATE_KEY_ID", create)
	t.Setenv("METON_MANAGED_READ_KEY_ID", read)
	t.Setenv("METON_MANAGED_FUNDS_READ_KEY_ID", funds)
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s1-closed-v1")
	op := uuid.NewString()
	const path = "/api/v1/admin/meton/managed-accounts/:operation/funds"
	for _, tc := range []struct {
		name, key, permission, tail, body string
		want                              int
	}{
		{"unauthenticated", "", "", "", "", 403}, {"create-key", create, "meton.funds.inspect", "", "", 403},
		{"other-read", read, "meton.funds.inspect", "", "", 403}, {"wrong-scope", funds, "meton.managed.read", "", "", 403},
		{"query-owner", funds, "meton.funds.inspect", "?user=12", "", 400}, {"body-owner", funds, "meton.funds.inspect", "", "{}", 400},
		{"missing-is-not-empty", funds, "meton.funds.inspect", "", "", 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &fundsProbe{}
			r := gin.New()
			r.Use(func(c *gin.Context) {
				if tc.key != "" {
					c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), &adminaccess.Principal{KeyID: tc.key, Policy: adminaccess.Policy{GlobalPermissions: []string{tc.permission}}}))
				}
				c.Next()
			})
			r.GET(path, (&UserHandler{adminService: store}).MetonFunds)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/v1/admin/meton/managed-accounts/"+op+"/funds"+tc.tail, strings.NewReader(tc.body)))
			if w.Code != tc.want || w.Header().Get("Cache-Control") != "no-store" || (store.calls == 1) != (tc.want == 404) {
				t.Fatalf("status %d / calls %d", w.Code, store.calls)
			}
		})
	}
	source, _ := service.MetonSource()
	s := service.MetonManagedClaim{Version: 1, Environment: "fixture", Source: "source", Epoch: 2, User: uuid.New(), Account: uuid.New(), Operation: uuid.New(), Dispatch: uuid.New()}
	now := time.Now().UTC()
	marker := uuid.New()
	x := service.MetonFundsReceipt{Version: 1, Origin: s, RemoteUser: 1, SourceMarker: uuid.New(), State: "controlled_empty", CheckedAt: now, ValidUntil: now.Add(5 * time.Second)}
	if source.ValidFunds(s.Operation, &x, now) {
		t.Fatal("empty without birth")
	}
	x.BirthMarker = &marker
	if !source.ValidFunds(s.Operation, &x, now) || source.ValidFunds(uuid.New(), &x, now) || source.ValidFunds(s.Operation, &x, x.ValidUntil) {
		t.Fatal("funds proof ownership or deadline")
	}
	t.Setenv("METON_MANAGED_FUNDS_MODE", "open")
	if _, ok := source.FundsID(); ok {
		t.Fatal("open monetary source signed S1")
	}
}
