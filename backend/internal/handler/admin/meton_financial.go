package admin

import (
	"context"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

func (h *UserHandler) SetMetonFinancialControl(c *service.MetonFinancialControl) {
	h.financialControl = c
}

/** 固定只读路由不接收账号、正文或查询条件，不能借分页或别名漏掉未结事项。 */
func (h *UserHandler) MetonFinancialObservation(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	req := c.Request
	p := adminaccess.FromContext(req.Context())
	if !h.financialControl.Allows(p) || h.settingService == nil || h.userService == nil {
		response.Forbidden(c, "financial observation unavailable")
		return
	}
	keys := req.Header.Values("X-Api-Key")
	if req.Method != http.MethodGet || c.FullPath() != "/api/v1/admin"+metonmodel.FinancialRoute || req.URL.Path != c.FullPath() ||
		req.URL.RawPath != "" || req.URL.RawQuery != "" || req.URL.ForceQuery || req.ContentLength != 0 || len(req.TransferEncoding) != 0 ||
		len(keys) != 1 || keys[0] == "" || len(req.Header.Values("Cookie")) != 0 || len(req.Header.Values("Authorization")) != 0 || len(req.Header.Values("Content-Encoding")) != 0 {
		response.BadRequest(c, "invalid financial observation request")
		return
	}
	ip := middleware.SecurityClientIP(c)
	deliver := func(ctx context.Context) bool {
		key, e := h.settingService.AuthenticateScopedAdminKey(ctx, keys[0], ip)
		if e != nil || key == nil || key.ID != p.KeyID || key.CreatedBy != p.CreatorID || !key.UpdatedAt.Equal(p.KeyRevision) || !adminaccess.RouteAllowed(key.Policy, req.Method, c.FullPath()) {
			return false
		}
		user, e := h.userService.GetByID(ctx, key.CreatedBy)
		return e == nil && user != nil && user.IsActive() && user.IsAdmin()
	}
	result, err := h.financialControl.Observe(req.Context(), p, keys[0], deliver)
	if err != nil {
		response.Error(c, 503, "financial observation unavailable")
		return
	}
	response.Success(c, result)
}
