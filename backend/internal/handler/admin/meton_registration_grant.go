package admin

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// readRegistrationGrant 每个标量按精确字段名只读一次，拒绝重复、大小写变体及第二份请求。
func readRegistrationGrant(body io.Reader) (*service.MetonRegistrationGrant, bool) {
	var q service.MetonRegistrationGrant
	fields := map[string]any{"version": &q.Version, "environment": &q.Environment, "source": &q.Source, "epoch": &q.Epoch,
		"user": &q.User, "account": &q.Account, "operation": &q.Operation, "dispatch": &q.Dispatch, "remoteUser": &q.RemoteUser,
		"sourceMarker": &q.SourceMarker, "eligibility": &q.Eligibility, "rule": &q.Rule, "unit": &q.Unit, "amount": &q.Amount}
	d := json.NewDecoder(body)
	if token, err := d.Token(); err != nil || token != json.Delim('{') {
		return nil, false
	}
	for d.More() {
		token, err := d.Token()
		name, ok := token.(string)
		dest := fields[name]
		if err != nil || !ok || dest == nil || d.Decode(dest) != nil {
			return nil, false
		}
		delete(fields, name)
	}
	end, err := d.Token()
	return &q, err == nil && end == json.Delim('}') && len(fields) == 0 && d.Decode(&struct{}{}) == io.EOF
}

// MetonRegistrationGrant 仅专用受限身份可操作原账户。读和写互斥，完整原凭证才向调用者确认到账。
func (h *UserHandler) MetonRegistrationGrant(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	write := c.Request.Method == http.MethodPost
	source, ok := service.MetonSource()
	key, enabled := source.GrantKeyID(write)
	p := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || p == nil || p.KeyID != key || !adminaccess.RouteAllowed(p.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "managed grant unavailable")
		return
	}
	creation, e1 := uuid.Parse(c.Param("operation"))
	grant, e2 := uuid.Parse(c.Param("eligibility"))
	if e1 != nil || e2 != nil || creation == uuid.Nil || grant == uuid.Nil || creation.String() != c.Param("operation") || grant.String() != c.Param("eligibility") ||
		c.Request.URL.RawQuery != "" || c.Request.URL.ForceQuery {
		response.BadRequest(c, "invalid original reference")
		return
	}
	var q *service.MetonRegistrationGrant
	if write {
		q, ok = readRegistrationGrant(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
		keys := c.Request.Header.Values("Idempotency-Key")
		if !ok || !source.ValidRegistrationGrant(q, creation, grant) || len(keys) != 1 || keys[0] != grant.String() {
			response.BadRequest(c, "invalid grant request")
			return
		}
	} else if c.Request.Method != http.MethodGet || c.Request.ContentLength != 0 || len(c.Request.TransferEncoding) != 0 {
		response.BadRequest(c, "invalid original lookup")
		return
	}
	store, available := h.adminService.(service.MetonGrantStore)
	if !available {
		response.Error(c, 503, "grant unconfirmed")
		return
	}
	result, err := store.RegistrationGrant(c.Request.Context(), source, creation, grant, q)
	if errors.Is(err, service.ErrMetonGrantConflict) {
		response.Error(c, http.StatusConflict, "original grant requires reconciliation")
		return
	}
	if err != nil || write && result == nil {
		response.Error(c, 503, "grant unconfirmed")
		return
	}
	if result == nil {
		response.NotFound(c, "grant unconfirmed")
		return
	}
	response.Success(c, result)
}
