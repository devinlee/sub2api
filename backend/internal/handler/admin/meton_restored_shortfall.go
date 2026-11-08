package admin

import (
	"context"
	"io"
	"mime"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

/** 只有启动装配能安装恢复差额入口；按路由选定用途，不采信正文指定的动作或身份。 */
func (h *UserHandler) SetMetonRestoredShortfallControl(c *service.MetonRestoredShortfallControl) {
	h.restoredShortfallControl = c
}

func (h *UserHandler) RestoredShortfallHandler(action string) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		p := adminaccess.FromContext(c.Request.Context())
		if !h.restoredShortfallControl.Allows(action, p) || c.FullPath() != "/api/v1/admin"+metonmodel.RestoredShortfallRoute+action ||
			h.settingService == nil || h.userService == nil {
			response.Forbidden(c, "restored shortfall unavailable")
			return
		}
		creation, err := uuid.Parse(c.Param("operation"))
		op, opErr := uuid.Parse(c.Param("request"))
		caller := c.Param("caller")
		req := c.Request
		media, _, mediaErr := mime.ParseMediaType(c.GetHeader("Content-Type"))
		keys := req.Header.Values("X-Api-Key")
		if err != nil || creation == uuid.Nil || creation.String() != c.Param("operation") || opErr != nil || op == uuid.Nil || op.String() != c.Param("request") ||
			(caller != "meton.chat.v1" && caller != "meton.oc07.v1") || req.Method != http.MethodPost || req.URL.RawPath != "" || req.URL.RawQuery != "" || req.URL.ForceQuery ||
			len(keys) != 1 || keys[0] == "" || len(req.Header.Values("Cookie")) != 0 || len(req.Header.Values("Authorization")) != 0 ||
			len(req.Header.Values("Content-Encoding")) != 0 || mediaErr != nil || media != "application/json" || req.ContentLength > 8192 {
			response.BadRequest(c, "invalid restored shortfall request")
			return
		}
		raw, err := io.ReadAll(io.LimitReader(req.Body, 8193))
		if err != nil {
			response.BadRequest(c, "invalid restored shortfall request")
			return
		}
		q, err := metonmodel.ReadRestoredShortfall(action, raw)
		if err != nil {
			response.BadRequest(c, "invalid restored shortfall request")
			return
		}
		// 资金提交后可能撤销、轮换或停用管理员。交付再走一次原鉴权，不重试已经提交的命令。
		ip := middleware.SecurityClientIP(c)
		deliver := func(ctx context.Context) bool {
			key, e := h.settingService.AuthenticateScopedAdminKey(ctx, keys[0], ip)
			if e != nil || key == nil || key.ID != p.KeyID || key.CreatedBy != p.CreatorID || !key.UpdatedAt.Equal(p.KeyRevision) ||
				!adminaccess.RouteAllowed(key.Policy, req.Method, c.FullPath()) {
				return false
			}
			user, e := h.userService.GetByID(ctx, key.CreatedBy)
			return e == nil && user != nil && user.IsActive() && user.IsAdmin()
		}
		result, err := h.restoredShortfallControl.Execute(req.Context(), creation, caller, op, action, *q, p, keys[0], deliver)
		if err != nil {
			response.Error(c, 503, "original restored shortfall unconfirmed")
			return
		}
		if result == nil {
			response.NotFound(c, "original restored shortfall unconfirmed")
			return
		}
		response.Success(c, result)
	}
}
