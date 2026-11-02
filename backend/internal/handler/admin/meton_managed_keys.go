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

// 本入口不收模型用户的 Web 身份。只读检查不能返回签发秘密，缓存及通用管理 JWT 均无权替代。
func (h *UserHandler) MetonManagedKey(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	s, ok := service.CurrentMetonKeySource()
	p := adminaccess.FromContext(c.Request.Context())
	expected := s.InspectID
	if c.Request.Method == http.MethodPost {
		expected = s.IssueID
	}
	if !ok || p == nil || p.KeyID != expected || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "managed key unavailable")
		return
	}
	var claim *service.MetonKeyRequest
	var op uuid.UUID
	switch c.Request.Method {
	case http.MethodPost:
		var v service.MetonKeyRequest
		decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&v) != nil || decoder.Decode(&struct{}{}) != io.EOF || !s.CanIssue(&v, time.Now()) || c.GetHeader("Idempotency-Key") != v.Claim.Operation.String() {
			response.BadRequest(c, "invalid key operation")
			return
		}
		claim = &v
		op = v.Claim.Operation
	case http.MethodGet:
		id, err := uuid.Parse(c.Param("operation"))
		if err != nil || id == uuid.Nil || id.String() != c.Param("operation") {
			response.BadRequest(c, "invalid key reference")
			return
		}
		op = id
	default:
		response.Forbidden(c, "managed key unavailable")
		return
	}
	store, ok := h.adminService.(service.MetonKeyStore)
	if !ok {
		response.Error(c, 503, "managed key unavailable")
		return
	}
	receipt, err := store.ManagedKey(c.Request.Context(), s, op, claim)
	if err != nil {
		response.Error(c, 503, "key result unconfirmed")
		return
	}
	if receipt == nil {
		response.NotFound(c, "key creation unconfirmed")
		return
	}
	if !s.AllowsReply(op, claim, receipt) {
		response.Error(c, 503, "key lookup invalid")
		return
	}
	response.Success(c, receipt)
}
