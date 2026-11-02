package admin

import (
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"io"
	"net/http"
)

// MetonManaged 只认当前来源的专用受限管理身份。普通/全权管理 JWT 持有者不能替代专用密钥。
func (h *UserHandler) MetonManaged(c *gin.Context) {
	source, ok := service.MetonSource()
	p := adminaccess.FromContext(c.Request.Context())
	expected := source.ReadKeyID
	if c.Request.Method == http.MethodPost {
		expected = source.CreateKeyID
	}
	if !ok || p == nil || p.KeyID != expected || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "managed source unavailable")
		return
	}
	var claim *service.MetonManagedClaim
	var op uuid.UUID
	if c.Request.Method == http.MethodPost {
		var v service.MetonManagedClaim
		decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&v) != nil || decoder.Decode(&struct{}{}) != io.EOF || !source.ValidClaim(&v) || c.GetHeader("Idempotency-Key") != v.Operation.String() {
			response.BadRequest(c, "invalid managed operation")
			return
		}
		claim = &v
		op = v.Operation
	} else if c.Request.Method == http.MethodGet {
		parsed, err := uuid.Parse(c.Param("operation"))
		if err != nil || parsed == uuid.Nil || parsed.String() != c.Param("operation") {
			response.BadRequest(c, "invalid managed reference")
			return
		}
		op = parsed
	} else {
		response.Forbidden(c, "managed source unavailable")
		return
	}
	port, ok := h.adminService.(service.MetonManagedStore)
	if !ok {
		response.Error(c, 503, "managed source unavailable")
		return
	}
	result, err := port.ManagedAccount(c.Request.Context(), source, op, claim)
	if err != nil {
		response.Error(c, 503, "managed result unconfirmed")
		return
	}
	if result == nil {
		response.NotFound(c, "managed creation unconfirmed")
		return
	}
	response.Success(c, result)
}
