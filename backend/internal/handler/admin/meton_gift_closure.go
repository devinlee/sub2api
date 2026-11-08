package admin

import (
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"io"
	"mime"
	"net/http"
)

/** SetMetonGiftClosure 只供监听前组合；普通管理仓储不能代替专用来源权限。 */
func (h *UserHandler) SetMetonGiftClosure(control *service.MetonGiftClosure) { h.giftClosure = control }
func (h *UserHandler) MetonGiftInspect(c *gin.Context)                       { h.metonGiftClosure(c, "inspect") }
func (h *UserHandler) MetonGiftTerminate(c *gin.Context)                     { h.metonGiftClosure(c, "terminate") }
func (h *UserHandler) MetonGiftReconcile(c *gin.Context)                     { h.metonGiftClosure(c, "reconcile") }

/** metonGiftClosure 查询也用固定结构的请求体传完整原范围，但只持只读数据库权限。 */
func (h *UserHandler) metonGiftClosure(c *gin.Context, action string) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	id, enabled := source.GiftClosureKeyID(action != "inspect")
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || p == nil || p.KeyID != id || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "gift closure unavailable")
		return
	}
	creation, err := uuid.Parse(c.Param("operation"))
	media, _, mediaErr := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if c.Request.Method != http.MethodPost || err != nil || creation == uuid.Nil || creation.String() != c.Param("operation") ||
		c.Request.URL.RawQuery != "" || c.Request.URL.RawPath != "" || c.Request.URL.ForceQuery || mediaErr != nil || media != "application/json" ||
		c.GetHeader("Content-Encoding") != "" || c.Request.ContentLength > 4096 {
		response.BadRequest(c, "invalid gift closure")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 4097))
	var q service.MetonGiftRequest
	if err != nil || len(raw) > 4096 || service.ReadMetonGiftRequest(raw, &q) != nil || !source.ValidGiftRequest(q, action) || q.Scope.Operation != creation {
		response.BadRequest(c, "invalid original gift scope")
		return
	}
	keys := c.Request.Header.Values("Idempotency-Key")
	if action == "inspect" && len(keys) != 0 || action != "inspect" && (len(keys) != 1 || keys[0] != q.Final.Decision.String()) {
		response.BadRequest(c, "invalid original decision")
		return
	}
	result, err := h.giftClosure.Execute(c.Request.Context(), source, action, q)
	if errors.Is(err, service.ErrMetonGiftConflict) {
		response.Error(c, http.StatusConflict, "original gift closure requires reconciliation")
		return
	}
	if err != nil || result == nil {
		response.Error(c, 503, "gift closure unconfirmed")
		return
	}
	response.Success(c, result)
}
