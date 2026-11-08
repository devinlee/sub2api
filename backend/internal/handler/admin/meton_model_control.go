package admin

import (
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"io"
	"mime"
	"net/http"
)

/** SetMetonModelControl 仅供启动装配，在监听请求前设置；没有原生仓储或默认资金权限后备。 */
func (h *UserHandler) SetMetonModelControl(control *service.MetonModelControl) {
	h.modelControl = control
}

/** MetonModelExecution 只读原发送裁决；prepared 不代表后续一定不会执行。 */
func (h *UserHandler) MetonModelExecution(c *gin.Context) { h.metonModelControl(c, false) }

/** MetonModelCancel 使用独立取消身份，只能要求来源沿原操作裁决，不能指定退款或释放金额。 */
func (h *UserHandler) MetonModelCancel(c *gin.Context) { h.metonModelControl(c, true) }

func (h *UserHandler) metonModelControl(c *gin.Context, cancel bool) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	id, allowed := source.ModelReadID()
	method := http.MethodGet
	if cancel {
		id, allowed = source.ModelCancelID()
		method = http.MethodPost
	}
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !allowed || p == nil || p.KeyID != id || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "original execution unavailable")
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
	if c.Request.Method != method || !validCreation || !validOperation || (caller != "meton.chat.v1" && caller != "meton.oc07.v1") ||
		c.Request.URL.RawQuery != "" || c.Request.URL.ForceQuery || (!cancel && (c.Request.ContentLength != 0 || len(c.Request.TransferEncoding) != 0)) {
		response.BadRequest(c, "invalid original execution")
		return
	}
	var request *metonmodel.Cancellation
	if cancel {
		media, _, err := mime.ParseMediaType(c.GetHeader("Content-Type"))
		if err != nil || media != "application/json" || c.Request.ContentLength > 8192 || c.GetHeader("Content-Encoding") != "" {
			response.BadRequest(c, "invalid original cancellation")
			return
		}
		body, err := io.ReadAll(io.LimitReader(c.Request.Body, 8193))
		if err != nil {
			response.BadRequest(c, "invalid original cancellation")
			return
		}
		request, err = metonmodel.ReadCancellation(body)
		if err != nil || request.Admission.Origin.Caller != caller || request.Admission.Origin.OperationID != operation.String() {
			response.BadRequest(c, "invalid original cancellation")
			return
		}
	}
	raw, err := h.modelControl.Execute(c.Request.Context(), source, creation, caller, operation, request)
	if err != nil {
		response.Error(c, 503, "original execution unconfirmed")
		return
	}
	if len(raw) == 0 {
		response.NotFound(c, "original execution unconfirmed")
		return
	}
	response.Success(c, raw)
}
