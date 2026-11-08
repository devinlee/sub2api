package admin

import (
	"encoding/json"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

/** MetonModelRead 仅交回原受理或指定原费用，拒绝别名、额外主体输入和任何写入方法。 */
func (h *UserHandler) MetonModelRead(c *gin.Context) {
	h.metonModelRead(c, false)
}

/** MetonModelResult 只按原创建和原操作定位终局，不从当前登录账号猜原归属。 */
func (h *UserHandler) MetonModelResult(c *gin.Context) {
	h.metonModelRead(c, true)
}

func (h *UserHandler) metonModelRead(c *gin.Context, result bool) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	id, allowed := source.ModelReadID()
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !allowed || p == nil || p.KeyID != id || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "original model reference unavailable")
		return
	}
	parse := func(name string) (uuid.UUID, bool) {
		raw := c.Param(name)
		v, err := uuid.Parse(raw)
		return v, err == nil && v != uuid.Nil && v.String() == raw
	}
	creation, validCreation := parse("operation")
	operation, validOperation := parse("request")
	caller := c.Param("caller")
	var event *uuid.UUID
	if c.Param("event") != "" {
		v, valid := parse("event")
		if !valid {
			response.BadRequest(c, "invalid original reference")
			return
		}
		event = &v
	}
	if c.Request.Method != http.MethodGet || !validCreation || !validOperation || (caller != "meton.chat.v1" && caller != "meton.oc07.v1") ||
		c.Request.URL.RawQuery != "" || c.Request.URL.ForceQuery || c.Request.ContentLength != 0 || len(c.Request.TransferEncoding) != 0 {
		response.BadRequest(c, "invalid original reference")
		return
	}
	var raw json.RawMessage
	err := service.ErrMetonClosed
	if result {
		if port, ok := h.adminService.(service.MetonModelResultStore); ok && event == nil {
			raw, err = port.OriginalModelResult(c.Request.Context(), source, creation, caller, operation)
		}
	} else if port, ok := h.adminService.(service.MetonModelReadStore); ok {
		raw, err = port.OriginalModel(c.Request.Context(), source, creation, caller, operation, event)
	}
	if err != nil {
		response.Error(c, 503, "original model reference unconfirmed")
		return
	}
	if len(raw) == 0 {
		response.NotFound(c, "original model reference unconfirmed")
		return
	}
	response.Success(c, raw)
}
