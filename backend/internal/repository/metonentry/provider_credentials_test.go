//go:build unit && meton_managed

package metonentry

import (
	"context"
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"testing"
)

type originalProviderAccounts struct {
	account   *service.Account
	err       error
	calls     int
	requested int64
}

func (a *originalProviderAccounts) GetByID(_ context.Context, id int64) (*service.Account, error) {
	a.calls++
	a.requested = id
	return a.account, a.err
}

func TestOriginalProviderCredentials(t *testing.T) {
	for _, mode := range []string{"original", "foreign", "inactive", "oauth", "shadow", "missing", "unavailable"} {
		t.Run(mode, func(t *testing.T) {
			a := &service.Account{ID: 23, Platform: service.PlatformOpenAI, Type: service.AccountTypeAPIKey, Status: service.StatusActive, Credentials: map[string]any{"api_key": "isolated-original", "organization_id": "org-original", "project_id": "project-original"}}
			store := &originalProviderAccounts{account: a}
			parent := int64(47)
			switch mode {
			case "foreign":
				a.ID = 47
			case "inactive":
				a.Status = "inactive"
			case "oauth":
				a.Type = "oauth"
			case "shadow":
				a.ParentAccountID = &parent
			case "missing":
				delete(a.Credentials, "api_key")
			case "unavailable":
				store.err = errors.New("isolated read unavailable")
			}
			got, e := ProviderCredentials(store)(t.Context(), 23)
			if mode == "original" {
				if e != nil || got.Get("Authorization") != "Bearer isolated-original" || got.Get("OpenAI-Organization") != "org-original" || got.Get("OpenAI-Project") != "project-original" {
					t.Fatal("未取原账户材料", e)
				}
			} else if e == nil {
				t.Fatal("无效供应账户通过", mode)
			}
			if store.calls != 1 || store.requested != 23 {
				t.Fatal("发生账户回退或自动重读")
			}
		})
	}
}
