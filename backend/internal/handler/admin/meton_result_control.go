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

/** SetMetonResultControl 只由启动装配设置，不从用户表单或旧管理身份启用。 */
func (h *UserHandler) SetMetonResultControl(control *service.MetonResultControl) {
	h.resultControl = control
}

/** MetonResultObserve 只登记原供应观察，不执行结算。 */
func (h *UserHandler) MetonResultObserve(c *gin.Context) { h.metonResultControl(c, "observe") }

/** MetonResultProof 只读已经登记的证明，不触发供应请求。 */
func (h *UserHandler) MetonResultProof(c *gin.Context) { h.metonResultControl(c, "proof") }

/** MetonResultApply 只选用指定原证明，不接收人工金额。 */
func (h *UserHandler) MetonResultApply(c *gin.Context) { h.metonResultControl(c, "apply") }

/** MetonResultResolution 只查原结算；缺少凭证时不再次执行。 */
func (h *UserHandler) MetonResultResolution(c *gin.Context) { h.metonResultControl(c, "resolution") }

/** 三种身份各自复验实际路由；查询虽携带结构化原引用，仍只读取，不因查无而补执行。 */
func (h *UserHandler) metonResultControl(c *gin.Context, action string) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	id, enabled := source.ResultControlID(action)
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || p == nil || p.KeyID != id || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "original reconciliation unavailable")
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
		response.BadRequest(c, "invalid original reconciliation")
		return
	}
	body, err := io.ReadAll(io.LimitReader(c.Request.Body, 8193))
	if err != nil {
		response.BadRequest(c, "invalid original reconciliation")
		return
	}
	q, err := metonmodel.ReadReconciliation(body)
	if err != nil {
		response.BadRequest(c, "invalid original reconciliation")
		return
	}
	raw, err := h.resultControl.Execute(c.Request.Context(), source, creation, caller, operation, action, *q)
	if err != nil {
		response.Error(c, 503, "original reconciliation unconfirmed")
		return
	}
	if len(raw) == 0 {
		response.NotFound(c, "original reconciliation unconfirmed")
		return
	}
	response.Success(c, raw)
}
