//go:build meton_managed

package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/wechatpay-apiv3/wechatpay-go/core/notify"
)

var externalReturnReference = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
var externalReturnFen = regexp.MustCompile(`^[1-9][0-9]{0,17}$`)

/** VerifyIsolatedExternalReturn 是本地夹具协议，不是微信正式通知类型；真实商户实例不能使用。 */
func (w *Wxpay) VerifyIsolatedExternalReturn(ctx context.Context, raw []byte, headers http.Header) (*payment.ExternalCashReturn, error) {
	bad := payment.ErrInvalidCashNotice
	if w.checkoutClient == nil {
		return nil, bad
	}
	transport, isolated := w.checkoutClient.Transport.(checkoutLocalNative)
	if !isolated || !IsCheckoutSimulator("http://"+transport.target) {
		return nil, bad
	}
	var shape notify.Request
	if len(raw) == 0 || len(raw) > 1<<20 || metonexecution.DecodeStrict(raw, &shape) != nil ||
		shape.Resource == nil || len(shape.Resource.Nonce) != 12 || shape.Resource.Ciphertext == "" ||
		shape.ResourceType != "encrypt-resource" || shape.CreateTime == nil || !noticeReference.MatchString(shape.ID) ||
		shape.Resource.OriginalType != "meton-isolated-cash-return" ||
		shape.EventType != payment.IsolatedChargebackEvent && shape.EventType != payment.IsolatedReversalEvent {
		return nil, bad
	}
	if _, err := checkoutSignature(headers); err != nil ||
		headers.Get("Wechatpay-Signature-Type") != "" && headers.Get("Wechatpay-Signature-Type") != "WECHATPAY2-SHA256-RSA2048" {
		return nil, bad
	}
	if _, err := w.ensureClient(); err != nil {
		return nil, bad
	}
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, "/", bytes.NewReader(raw))
	if err != nil {
		return nil, bad
	}
	r.Header = headers.Clone()
	var clear json.RawMessage
	if _, err = w.notifyHandler.ParseNotifyRequest(ctx, r, &clear); err != nil {
		return nil, bad
	}
	var resource struct {
		Merchant string                     `json:"mchid"`
		App      string                     `json:"appid"`
		Facts    payment.ExternalCashReturn `json:"facts"`
	}
	if metonexecution.DecodeStrict(clear, &resource) != nil || resource.Merchant != w.config["mchId"] || resource.App != w.config["appId"] {
		return nil, bad
	}
	f := resource.Facts
	kind := "chargeback"
	if shape.EventType == payment.IsolatedReversalEvent {
		kind = "reversal"
	}
	stamp, err := time.Parse(time.RFC3339Nano, f.OccurredAt)
	if err != nil || stamp.Year() < 1 || stamp.Year() > 9999 || f.Format != 1 || f.Kind != kind ||
		!externalReturnReference.MatchString(f.Reference) || !noticeReference.MatchString(f.Order) ||
		!noticeReference.MatchString(f.Transaction) || f.Currency != "CNY" || !externalReturnFen.MatchString(f.ReturnedFen) {
		return nil, bad
	}
	f.OccurredAt = stamp.UTC().Format(time.RFC3339Nano)
	return &f, nil
}
