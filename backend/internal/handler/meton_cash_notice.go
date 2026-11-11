package handler

import (
	"context"
	"errors"
	"io"
	"mime"
	"net/http"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

/** SetManagedCash 在启动时装配独立收件权威，缺配置保留关闭。 */
func (h *PaymentWebhookHandler) SetManagedCash(s *service.MetonCashNotifications) { h.managedCash = s }
func (h *PaymentWebhookHandler) ManagedCashReady() bool                           { return h != nil && h.managedCash != nil }

/** managedWxpayNotice 只在可靠收件完成后答复 204。原文、签名和 SDK 错误均不进入普通日志。 */
func (h *PaymentWebhookHandler) managedWxpayNotice(c *gin.Context) {
	r := c.Request
	c.Header("Cache-Control", "no-store")
	fail := func(status int) { c.JSON(status, gin.H{"code": "FAIL", "message": "通知尚未确认"}) }
	if !h.ManagedCashReady() {
		fail(503)
		return
	}
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if r.Method != http.MethodPost || r.URL.RequestURI() != service.NativeCashWebhook ||
		len(r.Header.Values("Content-Type")) != 1 || media != "application/json" || err != nil ||
		(r.Header.Get("Content-Encoding") != "" && r.Header.Get("Content-Encoding") != "identity") ||
		len(r.Trailer) > 0 {
		fail(400)
		return
	}
	for name, want := range map[string]string{"X-Original-URI": service.PublicCashWebhook, "X-Forwarded-Proto": "https", "X-Forwarded-Host": h.managedCash.Callback.Host} {
		values := r.Header.Values(name)
		if len(values) != 1 || values[0] != want {
			fail(400)
			return
		}
	}
	signature := http.Header{}
	for _, name := range []string{"Wechatpay-Serial", "Wechatpay-Signature", "Wechatpay-Nonce", "Wechatpay-Timestamp", "Wechatpay-Signature-Type"} {
		values := r.Header.Values(name)
		if len(values) == 0 && name == "Wechatpay-Signature-Type" {
			continue
		}
		if len(values) != 1 || values[0] == "" || len(values[0]) > 4096 {
			fail(400)
			return
		}
		signature.Set(name, values[0])
	}
	raw, err := io.ReadAll(http.MaxBytesReader(c.Writer, r.Body, maxWebhookBodySize))
	if err != nil {
		fail(400)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3500*time.Millisecond)
	defer cancel()
	switch err = h.managedCash.Receive(ctx, raw, signature); {
	case err == nil:
		c.Status(http.StatusNoContent)
	case errors.Is(err, payment.ErrInvalidCashNotice):
		fail(400)
	case errors.Is(err, payment.ErrCashNoticeConflict):
		fail(409)
	default:
		fail(503)
	}
}
