package admin

import (
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"io"
	"mime"
	"net/http"
)

/** 仅在监听前装配，归档范围不会因当前登录会员或 URL 中的账号而变化。 */
func (h *UserHandler) SetMetonCashArchive(query *service.MetonCashArchive) { h.cashArchive = query }

/** 归档读取与账号账单是不同的权限；本入口不能领取队列、解密原文或执行退款。 */
func (h *UserHandler) MetonCashArchive(c *gin.Context) { h.readCashArchive(c, false) }

/** 原账务关联沿单独的只读路由许可，不能用观察证明调用任何资金执行方法。 */
func (h *UserHandler) MetonCashArchiveOriginal(c *gin.Context) { h.readCashArchive(c, true) }

/** 两类查询共用完整输入与当前身份检查，未知结果不通过别的身份或方法重试。 */
func (h *UserHandler) readCashArchive(c *gin.Context, original bool) {
	c.Header("Cache-Control", "no-store")
	source, ok := service.MetonSource()
	key, enabled := source.CashArchiveKeyID()
	principal := adminaccess.FromContext(c.Request.Context())
	if !ok || !enabled || principal == nil || principal.KeyID != key || !adminaccess.RouteAllowed(principal.Policy, c.Request.Method, c.FullPath()) {
		response.Forbidden(c, "cash archive unavailable")
		return
	}
	media, _, err := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if c.Request.Method != http.MethodPost || c.Request.URL.RawQuery != "" || c.Request.URL.RawPath != "" || c.Request.URL.ForceQuery || err != nil || media != "application/json" ||
		c.GetHeader("Content-Encoding") != "" || c.Request.ContentLength > 4096 || len(c.Request.Header.Values("Idempotency-Key")) != 0 {
		response.BadRequest(c, "invalid archive request")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 4097))
	var q service.CashArchiveRequest
	if err != nil || len(raw) > 4096 || service.ReadCashArchiveRequest(raw, &q) != nil || !source.ValidCashArchive(q) || original && q.OriginalKey == nil {
		response.BadRequest(c, "invalid archive scope")
		return
	}
	var value []byte
	if original {
		value, err = h.cashArchive.ReadOriginal(c.Request.Context(), source, q)
	} else {
		value, err = h.cashArchive.Read(c.Request.Context(), source, q)
	}
	if err != nil || value == nil {
		response.Error(c, 503, "cash archive unconfirmed")
		return
	}
	response.Success(c, json.RawMessage(value))
}
