package admin

import (
	"io"
	"mime"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

/** 只由启动装配传入，不允许管理员通过表单临时开启。 */
func (h *UserHandler) SetMetonShortfallControl(control *service.MetonShortfallControl) {
	h.shortfallControl = control
}

/** MetonShortfallApply 执行原子步骤，不接收金额或新请求身份。 */
func (h *UserHandler) MetonShortfallApply(c *gin.Context) { h.metonShortfall(c, "apply") }

/** MetonShortfallResolution 只读原子步骤，没有查无补执行。 */
func (h *UserHandler) MetonShortfallResolution(c *gin.Context) { h.metonShortfall(c, "resolution") }

/** 原人员审核位于 Meton；此处额外核对独立服务身份和精确路由，不继承普通管理权限。 */
func (h *UserHandler) metonShortfall(c *gin.Context, action string) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	id, enabled := source.ShortfallControlID(action)
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || p == nil || p.KeyID != id || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "original shortfall unavailable")
		return
	}
	parse := func(name string) (uuid.UUID, bool) {
		raw := c.Param(name)
		value, err := uuid.Parse(raw)
		return value, err == nil && value != uuid.Nil && value.String() == raw
	}
	creation, cOK := parse("operation")
	operation, oOK := parse("request")
	caller := c.Param("caller")
	media, _, err := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if c.Request.Method != http.MethodPost || !cOK || !oOK || (caller != "meton.chat.v1" && caller != "meton.oc07.v1") ||
		c.Request.URL.RawQuery != "" || c.Request.URL.ForceQuery || c.Request.URL.RawPath != "" || c.GetHeader("Cookie") != "" ||
		err != nil || media != "application/json" || c.Request.ContentLength > 8192 || c.GetHeader("Content-Encoding") != "" {
		response.BadRequest(c, "invalid original shortfall")
		return
	}
	body, err := io.ReadAll(io.LimitReader(c.Request.Body, 8193))
	if err != nil {
		response.BadRequest(c, "invalid original shortfall")
		return
	}
	q, err := metonmodel.ReadShortfall(body)
	if err != nil {
		response.BadRequest(c, "invalid original shortfall")
		return
	}
	raw, err := h.shortfallControl.Execute(c.Request.Context(), source, creation, caller, operation, action, *q)
	if err != nil {
		response.Error(c, 503, "original shortfall unconfirmed")
		return
	}
	if len(raw) == 0 {
		response.NotFound(c, "original shortfall unconfirmed")
		return
	}
	response.Success(c, raw)
}
