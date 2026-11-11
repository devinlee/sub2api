package admin

import (
	"encoding/json"
	"io"
	"mime"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

/** 两条固定路由分别授权；查询原回执不转换成重试，也不接受 URL 或请求体选择执行方法。 */
func (h *UserHandler) MetonCashOriginalRetry(c *gin.Context)       { h.cashOriginalRetry(c, "retry") }
func (h *UserHandler) MetonCashOriginalRetryResult(c *gin.Context) { h.cashOriginalRetry(c, "result") }

func (h *UserHandler) cashOriginalRetry(c *gin.Context, action string) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	key, enabled := source.CashOriginalRetryKeyID()
	principal := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || principal == nil || principal.KeyID != key || !adminaccess.RouteAllowed(principal.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "cash original action unavailable")
		return
	}
	media, _, err := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if c.Request.Method != http.MethodPost || c.Request.URL.RawQuery != "" || c.Request.URL.RawPath != "" || c.Request.URL.ForceQuery ||
		err != nil || media != "application/json" || c.GetHeader("Content-Encoding") != "" || c.Request.ContentLength > 8192 || len(c.Request.Header.Values("Idempotency-Key")) != 0 {
		response.BadRequest(c, "invalid original action")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 8193))
	var q service.CashOriginalRetryRequest
	if err != nil || len(raw) > 8192 || service.ReadCashOriginalRetryRequest(raw, &q) != nil || !source.ValidCashOriginalRetry(q, action) {
		response.BadRequest(c, "invalid original scope")
		return
	}
	value, err := h.cashArchive.RetryOriginal(c.Request.Context(), source, q, action)
	if err != nil || value == nil {
		response.Error(c, 503, "cash original result unknown")
		return
	}
	response.Success(c, json.RawMessage(value))
}
