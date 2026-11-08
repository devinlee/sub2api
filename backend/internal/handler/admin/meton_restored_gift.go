package admin

import (
	"context"
	"io"
	"mime"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

/** 仅供服务监听前安装当前恢复组件；旧注销服务不会成为后备写入口。 */
func (h *UserHandler) SetMetonRestoredGiftControl(control *service.MetonRestoredGiftControl) {
	h.restoredGiftControl = control
}

/** 路由决定读写用途，原生管理员身份在交付前再核对一次。 */
func (h *UserHandler) RestoredGiftHandler(action string) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		p := adminaccess.FromContext(c.Request.Context())
		req := c.Request
		if !h.restoredGiftControl.Allows(action, p) || c.FullPath() != "/api/v1/admin"+service.RestoredGiftRoute+action || h.settingService == nil || h.userService == nil {
			response.Forbidden(c, "restored gift unavailable")
			return
		}
		creation, err := uuid.Parse(c.Param("operation"))
		media, _, mediaErr := mime.ParseMediaType(c.GetHeader("Content-Type"))
		keys := req.Header.Values("X-Api-Key")
		if err != nil || creation == uuid.Nil || creation.String() != c.Param("operation") || req.Method != http.MethodPost || req.URL.RawQuery != "" || req.URL.RawPath != "" || req.URL.ForceQuery ||
			len(keys) != 1 || keys[0] == "" || len(req.Header.Values("Cookie")) != 0 || len(req.Header.Values("Authorization")) != 0 || len(req.Header.Values("Content-Encoding")) != 0 ||
			mediaErr != nil || media != "application/json" || req.ContentLength > 4096 {
			response.BadRequest(c, "invalid restored gift request")
			return
		}
		raw, err := io.ReadAll(io.LimitReader(req.Body, 4097))
		if err != nil || len(raw) > 4096 {
			response.BadRequest(c, "invalid restored gift request")
			return
		}
		q, err := service.ReadMetonRestoredGift(action, raw)
		if err != nil || q.Original.Scope.Operation != creation {
			response.BadRequest(c, "invalid original gift decision")
			return
		}
		idempotency := req.Header.Values("Idempotency-Key")
		if action == "inspect" && len(idempotency) != 0 || (action == "reconcile" || action == "terminate") && (len(idempotency) != 1 || idempotency[0] != q.Original.Final.Decision.String()) {
			response.BadRequest(c, "invalid original gift decision")
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
		result, err := h.restoredGiftControl.Execute(req.Context(), creation, action, *q, p, keys[0], deliver)
		if err != nil || result == nil {
			response.Error(c, 503, "original restored gift unconfirmed")
			return
		}
		response.Success(c, result)
	}
}
