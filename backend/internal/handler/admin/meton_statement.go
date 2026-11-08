package admin

import (
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"io"
	"mime"
	"net/http"
)

/** SetMetonStatements 仅监听前装配，查询对象不持有资金写端口。 */
func (h *UserHandler) SetMetonStatements(query *service.MetonStatements) { h.statements = query }
func (h *UserHandler) MetonStatementOpen(c *gin.Context)                 { h.metonStatement(c, false) }
func (h *UserHandler) MetonStatementPage(c *gin.Context)                 { h.metonStatement(c, true) }

/** metonStatement POST 仅传固定原范围；不接受任意 SQL、路径、Key 或写入操作。 */
func (h *UserHandler) metonStatement(c *gin.Context, page bool) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	id, enabled := source.StatementKeyID()
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || p == nil || p.KeyID != id || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "statement unavailable")
		return
	}
	original, err := uuid.Parse(c.Param("operation"))
	media, _, mediaErr := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if c.Request.Method != http.MethodPost || err != nil || original == uuid.Nil || original.String() != c.Param("operation") ||
		c.Request.URL.RawQuery != "" || c.Request.URL.RawPath != "" || c.Request.URL.ForceQuery || mediaErr != nil || media != "application/json" ||
		c.GetHeader("Content-Encoding") != "" || c.Request.ContentLength > 4096 || len(c.Request.Header.Values("Idempotency-Key")) != 0 {
		response.BadRequest(c, "invalid statement request")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 4097))
	var q service.MetonStatementRequest
	if err != nil || len(raw) > 4096 || service.ReadMetonStatementRequest(raw, &q) != nil || !source.ValidStatement(q) ||
		q.Scope.Operation != original || page != (q.Page != nil) {
		response.BadRequest(c, "invalid original statement")
		return
	}
	value, err := h.statements.Read(c.Request.Context(), source, q)
	if err != nil || value == nil {
		response.Error(c, 503, "statement unconfirmed")
		return
	}
	response.Success(c, value)
}
