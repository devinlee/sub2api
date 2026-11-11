package admin

import (
	"errors"
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

/** SetMetonCheckout 仅在监听前装配托管收银台。 */
func (h *UserHandler) SetMetonCheckout(checkout *service.MetonCheckout) { h.checkout = checkout }

/** CheckoutHandler 从已匹配的固定路由取用途和原号，客户端不能选择其他管理接口。 */
func (h *UserHandler) CheckoutHandler(action string) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		req := c.Request
		p := adminaccess.FromContext(req.Context())
		if !h.checkout.Allows(action, p) || h.settingService == nil || h.userService == nil ||
			!adminaccess.RouteAllowed(p.Policy, req.Method, c.FullPath()) {
			response.Forbidden(c, "checkout unavailable")
			return
		}
		creation, e1 := uuid.Parse(c.Param("operation"))
		intent, e2 := uuid.Parse(c.Param("intent"))
		key := req.Header.Values("X-Api-Key")
		idempotency := req.Header.Values("Idempotency-Key")
		query := service.CheckoutReadAction(action)
		limit := service.CheckoutBodyLimit(action)
		media, _, mediaErr := mime.ParseMediaType(req.Header.Get("Content-Type"))
		if e1 != nil || e2 != nil || creation == uuid.Nil || intent == uuid.Nil || req.Method != http.MethodPost ||
			c.FullPath() != "/api/v1/admin"+service.CheckoutRoute+action ||
			req.URL.Path != "/api/v1/admin/meton/managed-accounts/"+creation.String()+"/checkout/"+intent.String()+"/"+action ||
			req.URL.RawPath != "" || req.URL.RawQuery != "" || req.URL.ForceQuery ||
			len(key) != 1 || len(req.Header.Values("Content-Type")) != 1 || mediaErr != nil || media != "application/json" ||
			req.ContentLength > int64(limit) || len(req.Header.Values("Cookie")) != 0 || len(req.Header.Values("Authorization")) != 0 ||
			len(req.Header.Values("Content-Encoding")) != 0 || query && len(idempotency) != 0 ||
			!query && (len(idempotency) != 1 || idempotency[0] != intent.String()) {
			response.BadRequest(c, "invalid checkout request")
			return
		}
		wire, err := io.ReadAll(io.LimitReader(req.Body, int64(limit)+1))
		if err != nil || len(wire) == 0 || len(wire) > limit {
			response.BadRequest(c, "invalid checkout body")
			return
		}
		receipt, err := h.checkout.Run(req.Context(), action, creation, intent, wire, p, key[0])
		// 即使数据库事务已结束，材料返回给调用方前仍需确认管理员和密钥版本有效。
		// 这一次认证不可用时不能把已提交的写入报告成明确失败。
		if errors.Is(err, service.ErrCheckoutDenied) {
			response.Forbidden(c, "checkout denied")
			return
		}
		if errors.Is(err, service.ErrCheckoutConflict) {
			response.Error(c, http.StatusConflict, "checkout intent conflict")
			return
		}
		if err != nil {
			response.Error(c, http.StatusServiceUnavailable, "checkout unconfirmed")
			return
		}
		latest, err := h.settingService.AuthenticateScopedAdminKey(req.Context(), key[0], middleware.SecurityClientIP(c))
		if err != nil || latest == nil || latest.ID != p.KeyID || latest.CreatedBy != p.CreatorID ||
			!latest.UpdatedAt.Equal(p.KeyRevision) || !adminaccess.RouteAllowed(latest.Policy, req.Method, c.FullPath()) {
			response.Error(c, http.StatusServiceUnavailable, "checkout unconfirmed")
			return
		}
		owner, err := h.userService.GetByID(req.Context(), latest.CreatedBy)
		if err != nil || owner == nil || !owner.IsAdmin() || !owner.IsActive() || !h.checkout.Allows(action, p) {
			response.Error(c, http.StatusServiceUnavailable, "checkout unconfirmed")
			return
		}
		if receipt == nil {
			response.NotFound(c, "checkout original unavailable")
			return
		}
		if service.IsCheckoutClosureRefund(action) {
			response.Success(c, receipt.ClosureRefund)
			return
		}
		if service.IsCheckoutClosureScope(action) {
			response.Success(c, receipt.ClosureScope)
			return
		}
		if service.IsCheckoutClosure(action) {
			response.Success(c, receipt.ClosureCheck)
			return
		}
		if action == "lifecycle" {
			response.Success(c, gin.H{"version": 1, "origin": receipt.Origin, "registration": receipt.Intent, "accountFact": receipt.AccountFact, "state": receipt.State})
			return
		}
		response.Success(c, receipt)
	}
}
