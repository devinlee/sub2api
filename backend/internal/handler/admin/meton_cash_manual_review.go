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

/** 三条固定用途分别授权；请求体不能把读取或结果查询改成新的审核提交。 */
func (h *UserHandler) MetonCashReviewContext(c *gin.Context) { h.cashManualReview(c, "context") }
func (h *UserHandler) MetonCashReviewRecord(c *gin.Context)  { h.cashManualReview(c, "record") }
func (h *UserHandler) MetonCashReviewResult(c *gin.Context)  { h.cashManualReview(c, "result") }

func (h *UserHandler) cashManualReview(c *gin.Context, action string) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	key, enabled := source.CashManualReviewKeyID()
	principal := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || principal == nil || principal.KeyID != key || !adminaccess.RouteAllowed(principal.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "cash review unavailable")
		return
	}
	limit := int64(16384)
	if action == "record" {
		limit = 720896
	}
	media, _, err := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if c.Request.Method != http.MethodPost || c.Request.URL.RawQuery != "" || c.Request.URL.RawPath != "" || c.Request.URL.ForceQuery || err != nil || media != "application/json" ||
		c.GetHeader("Content-Encoding") != "" || c.Request.ContentLength > limit || len(c.Request.Header.Values("Idempotency-Key")) != 0 {
		response.BadRequest(c, "invalid review request")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, limit+1))
	if err != nil || int64(len(raw)) > limit {
		response.BadRequest(c, "invalid review request")
		return
	}
	var value json.RawMessage
	if action == "context" {
		var q service.CashArchiveRequest
		if service.ReadCashArchiveRequest(raw, &q) != nil || !source.ValidCashManualContext(q) {
			response.BadRequest(c, "invalid review scope")
			return
		}
		value, err = h.cashArchive.ReadManualReview(c.Request.Context(), source, q)
	} else {
		var q service.CashManualReviewRequest
		resultOnly := action == "result"
		if service.ReadCashManualReviewRequest(raw, &q) != nil || !source.ValidCashManualReview(q, resultOnly) {
			response.BadRequest(c, "invalid review scope")
			return
		}
		value, err = h.cashArchive.RecordManualReview(c.Request.Context(), source, q, resultOnly)
	}
	if err != nil || value == nil {
		response.Error(c, 503, "cash review result unknown")
		return
	}
	response.Success(c, json.RawMessage(value))
}
