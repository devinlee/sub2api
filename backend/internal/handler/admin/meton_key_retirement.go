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
	"time"
)

// 轮换写权和只读核对分开，不能通过当前会话的名称、其他 Key 或管理 JWT 对旧对象发起关停。
func (h *UserHandler) MetonKeyRetirement(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	s, ok := service.CurrentMetonKeySource()
	p := adminaccess.FromContext(c.Request.Context())
	rotation, known := s.RotationID()
	expected := s.InspectID
	if c.Request.Method == http.MethodPost {
		expected = rotation
	}
	if !ok || !known || p == nil || p.KeyID != expected || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "retirement unavailable")
		return
	}
	op, err := uuid.Parse(c.Param("operation"))
	if err != nil || op == uuid.Nil || op.String() != c.Param("operation") {
		response.BadRequest(c, "invalid retirement reference")
		return
	}
	var req *service.MetonRetireRequest
	if c.Request.Method == http.MethodPost {
		var input service.MetonRetireRequest
		dec := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
		dec.DisallowUnknownFields()
		if dec.Decode(&input) != nil || dec.Decode(&struct{}{}) != io.EOF || c.GetHeader("Idempotency-Key") != op.String() || !s.CanRetire(&input, op, time.Now()) {
			response.BadRequest(c, "invalid rotation")
			return
		}
		req = &input
	} else if c.Request.Method != http.MethodGet {
		response.Forbidden(c, "retirement unavailable")
		return
	}
	store, ok := h.adminService.(service.MetonRetireStore)
	if !ok {
		response.Error(c, 503, "retirement unavailable")
		return
	}
	r, err := store.ManagedRetirement(c.Request.Context(), s, op, req)
	if err != nil {
		response.Error(c, 503, "retirement unconfirmed")
		return
	}
	if r == nil {
		response.NotFound(c, "retirement unconfirmed")
		return
	}
	if r.Version != 1 || r.State != "retired" || !s.Valid(r.Claim) || r.Claim.Operation != op || r.KeyMarker == uuid.Nil || r.RemoteKey <= 0 || r.RetiredAt.IsZero() ||
		req != nil && (req.Claim != r.Claim || req.KeyMarker != r.KeyMarker || req.RemoteKey != r.RemoteKey) {
		response.Error(c, 503, "retirement mismatch")
		return
	}
	response.Success(c, r)
}
