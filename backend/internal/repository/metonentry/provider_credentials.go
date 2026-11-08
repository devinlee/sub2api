//go:build meton_managed

package metonentry

import (
	"context"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"net/http"
)

type ProviderAccountReader interface {
	GetByID(context.Context, int64) (*service.Account, error)
}

/** ProviderCredentials 只读原供应账户，当前材料仍须与首次出站摘要相符；不刷新 OAuth 或切换账户。 */
func ProviderCredentials(accounts ProviderAccountReader) metonprovider.Credentials {
	return func(ctx context.Context, id int64) (http.Header, error) {
		if ctx == nil || ctx.Err() != nil || accounts == nil || id < 1 {
			return nil, service.ErrMetonClosed
		}
		a, e := accounts.GetByID(ctx, id)
		if e != nil || a == nil || a.ID != id || !a.IsActive() || !a.IsOpenAIApiKey() || a.ParentAccountID != nil || ctx.Err() != nil {
			return nil, service.ErrMetonClosed
		}
		key := a.GetOpenAIApiKey()
		if key == "" {
			return nil, service.ErrMetonClosed
		}
		h := http.Header{"Authorization": []string{"Bearer " + key}}
		if org := a.GetCredential("organization_id"); org != "" {
			h.Set("OpenAI-Organization", org)
		}
		if project := a.GetCredential("project_id"); project != "" {
			h.Set("OpenAI-Project", project)
		}
		return h, nil
	}
}
