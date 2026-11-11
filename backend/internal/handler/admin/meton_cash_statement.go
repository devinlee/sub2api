package admin

import (
	"io"
	"mime"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

/** 现金只读接口沿原查询身份，只允许固定原归属和有界游标，不复用收银台写授权。 */
func (h *UserHandler) MetonCashStatement(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	key, enabled := source.StatementKeyID()
	principal := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || principal == nil || principal.KeyID != key || !adminaccess.RouteAllowed(principal.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "cash statement unavailable")
		return
	}
	operation, err := uuid.Parse(c.Param("operation"))
	media, _, mediaErr := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if c.Request.Method != http.MethodPost || err != nil || operation == uuid.Nil || operation.String() != c.Param("operation") ||
		c.Request.URL.RawQuery != "" || c.Request.URL.RawPath != "" || c.Request.URL.ForceQuery || mediaErr != nil || media != "application/json" ||
		c.GetHeader("Content-Encoding") != "" || c.Request.ContentLength > 4096 || len(c.Request.Header.Values("Idempotency-Key")) != 0 {
		response.BadRequest(c, "invalid cash statement request")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 4097))
	var query service.CashStatementRequest
	if err != nil || len(raw) > 4096 || service.ReadCashStatementRequest(raw, &query) != nil || !source.ValidCashStatement(query) || query.Scope.Operation != operation {
		response.BadRequest(c, "invalid original cash statement")
		return
	}
	value, err := h.statements.ReadCash(c.Request.Context(), source, query)
	if err != nil || value == nil {
		response.Error(c, 503, "cash statement unconfirmed")
		return
	}
	response.Success(c, value)
}
