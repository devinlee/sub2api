package admin

import (
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// MetonFunds 仅允许专用只读身份。查无、错代和未部署能力均不能交付空资金证明。
func (h *UserHandler) MetonFunds(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	id, allowed := source.FundsID()
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !allowed || p == nil || p.KeyID != id || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "managed funds unavailable")
		return
	}
	raw := c.Param("operation")
	op, err := uuid.Parse(raw)
	if c.Request.Method != http.MethodGet || err != nil || op == uuid.Nil || op.String() != raw || c.Request.URL.RawQuery != "" || c.Request.URL.ForceQuery ||
		c.Request.ContentLength != 0 || len(c.Request.TransferEncoding) != 0 {
		response.BadRequest(c, "invalid original reference")
		return
	}
	port, available := h.adminService.(service.MetonFundsStore)
	if !available {
		response.Error(c, 503, "managed funds unconfirmed")
		return
	}
	result, err := port.ManagedFunds(c.Request.Context(), source, op)
	if err != nil {
		response.Error(c, 503, "managed funds unconfirmed")
		return
	}
	if result == nil {
		response.NotFound(c, "managed funds unconfirmed")
		return
	}
	response.Success(c, result)
}
