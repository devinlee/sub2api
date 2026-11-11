package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/wechatpay-apiv3/wechatpay-go/core/notify"
)

var noticeReference = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

/** NoticePublicKey 返回本次实际验证用的公钥，随加密回执保存以便轮换后核实原签名。 */
func (w *Wxpay) NoticePublicKey() string { return formatPEM(w.config["publicKey"], "PUBLIC KEY") }

type noticeResource struct {
	App          string     `json:"appid"`
	Merchant     string     `json:"mchid"`
	Order        string     `json:"out_trade_no"`
	Transaction  string     `json:"transaction_id"`
	TradeType    string     `json:"trade_type"`
	TradeState   string     `json:"trade_state"`
	RefundOrder  string     `json:"out_refund_no"`
	RefundID     string     `json:"refund_id"`
	RefundStatus string     `json:"refund_status"`
	SuccessTime  *time.Time `json:"success_time"`
	Amount       struct {
		Total         *int64 `json:"total"`
		PayerTotal    *int64 `json:"payer_total"`
		Currency      string `json:"currency"`
		PayerCurrency string `json:"payer_currency"`
		Refund        *int64 `json:"refund"`
		PayerRefund   *int64 `json:"payer_refund"`
	} `json:"amount"`
}

/** VerifyCashNotice 按原字节验签解密，支付和退款分别解释。错误只返回类别，SDK 错误可能带原文。 */
func (w *Wxpay) VerifyCashNotice(ctx context.Context, raw []byte, headers http.Header) (*payment.CashNotice, error) {
	bad := payment.ErrInvalidCashNotice
	var shape notify.Request
	if len(raw) == 0 || len(raw) > 1<<20 || json.Unmarshal(raw, &shape) != nil || shape.Resource == nil ||
		len(shape.Resource.Nonce) != 12 || shape.Resource.Ciphertext == "" || shape.ResourceType != "encrypt-resource" ||
		shape.CreateTime == nil || !noticeReference.MatchString(shape.ID) {
		return nil, bad
	}
	if _, err := w.ensureClient(); err != nil {
		return nil, err
	}
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, "/", bytes.NewReader(raw))
	if err != nil {
		return nil, bad
	}
	r.Header = headers.Clone()
	var resource noticeResource
	verified, err := w.notifyHandler.ParseNotifyRequest(ctx, r, &resource)
	if err != nil {
		return nil, bad
	}
	a := resource.Amount
	if resource.Merchant != w.config["mchId"] || !noticeReference.MatchString(resource.Order) ||
		!noticeReference.MatchString(resource.Transaction) || a.Total == nil || *a.Total <= 0 ||
		a.PayerTotal == nil || *a.PayerTotal < 0 || *a.PayerTotal > *a.Total {
		return nil, bad
	}
	n := &payment.CashNotice{Delivery: verified.ID, Merchant: resource.Merchant, Order: resource.Order,
		Transaction: resource.Transaction, Total: *a.Total, PayerTotal: *a.PayerTotal}
	if resource.SuccessTime != nil {
		n.OccurredAt = resource.SuccessTime.UTC().Format(time.RFC3339Nano)
	}
	switch verified.EventType {
	case "TRANSACTION.SUCCESS":
		if verified.Resource.OriginalType != "transaction" || resource.TradeType != "NATIVE" || resource.TradeState != "SUCCESS" ||
			resource.App != w.config["appId"] || a.Currency != "CNY" || a.PayerCurrency != "CNY" || n.OccurredAt == "" {
			return nil, bad
		}
		n.Kind, n.State, n.App, n.Currency, n.PayerCurrency = "payment", resource.TradeState, resource.App, a.Currency, a.PayerCurrency
	case "REFUND.SUCCESS", "REFUND.CLOSED", "REFUND.ABNORMAL":
		// 微信退款通知没有 appid 和币种，用原退款、原实付及其原商户订单复验这些字段。
		if verified.Resource.OriginalType != "refund" || verified.EventType != "REFUND."+resource.RefundStatus ||
			!noticeReference.MatchString(resource.RefundOrder) || !noticeReference.MatchString(resource.RefundID) ||
			a.Refund == nil || *a.Refund <= 0 || *a.Refund > *a.Total || a.PayerRefund == nil || *a.PayerRefund < 0 ||
			*a.PayerRefund > *a.Refund || *a.PayerRefund > *a.PayerTotal || resource.RefundStatus == "SUCCESS" && n.OccurredAt == "" ||
			resource.App != "" && resource.App != w.config["appId"] || a.Currency != "" && a.Currency != "CNY" || a.PayerCurrency != "" && a.PayerCurrency != "CNY" {
			return nil, bad
		}
		n.Kind, n.State, n.RefundOrder, n.RefundID = "refund", resource.RefundStatus, resource.RefundOrder, resource.RefundID
		n.RefundFen, n.PayerRefund = a.Refund, a.PayerRefund
	default:
		return nil, bad
	}
	return n, nil
}
