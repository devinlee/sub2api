package admin

import (
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// 退出不使用已经撤销的用户登录。写权限与轮换、签发、只读权限均按原生身份及精确路线隔离。
func (h *UserHandler) MetonSessionClosure(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	s, ok := service.CurrentMetonKeySource()
	closeID, known := s.CloseID()
	p := adminaccess.FromContext(c.Request.Context())
	expected := s.InspectID
	if c.Request.Method == http.MethodPost {
		expected = closeID
	}
	if !ok || !known || p == nil || p.KeyID != expected || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "closure unavailable")
		return
	}
	op, err := uuid.Parse(c.Param("operation"))
	if err != nil || op == uuid.Nil || op.String() != c.Param("operation") {
		response.BadRequest(c, "invalid operation")
		return
	}
	var req *service.MetonSessionCloseRequest
	var target *uuid.UUID
	if c.Request.Method == http.MethodPost {
		var input service.MetonSessionCloseRequest
		dec := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
		dec.DisallowUnknownFields()
		if dec.Decode(&input) != nil || dec.Decode(&struct{}{}) != io.EOF || c.GetHeader("Idempotency-Key") != op.String() || !s.CanClose(&input, op, time.Now()) {
			response.BadRequest(c, "invalid session closure")
			return
		}
		req = &input
	} else if c.Request.Method == http.MethodGet {
		if raw := c.Param("binding"); raw != "" {
			id, err := uuid.Parse(raw)
			if err != nil || id == uuid.Nil || id.String() != raw {
				response.BadRequest(c, "invalid binding")
				return
			}
			target = &id
		}
	} else {
		response.Forbidden(c, "closure unavailable")
		return
	}
	store, ok := h.adminService.(service.MetonSessionClosureStore)
	if !ok {
		response.Error(c, 503, "closure unavailable")
		return
	}
	v, err := store.ManagedSessionClosure(c.Request.Context(), s, op, req, target)
	if err != nil {
		response.Error(c, 503, "closure unconfirmed")
		return
	}
	if v == nil {
		response.NotFound(c, "closure unconfirmed")
		return
	}
	if !s.ValidClosureReply(op, req, target, v) {
		response.Error(c, 503, "closure mismatch")
		return
	}
	response.Success(c, v)
}
