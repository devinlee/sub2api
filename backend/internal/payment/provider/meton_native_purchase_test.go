//go:build unit

package provider

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/wechatpay-apiv3/wechatpay-go/core"
	"github.com/wechatpay-apiv3/wechatpay-go/services/payments/native"
)

/** TestMetonNativeOriginalPrepay 只替换微信 SDK 的发送端，沿真实适配核对原单和各种响应。 */
func TestMetonNativeOriginalPrepay(t *testing.T) {
	previous := wxpayNativePrepay
	t.Cleanup(func() { wxpayNativePrepay = previous })

	const order = "02d47587e3c949618e79f9895727fa13"
	const notifyURL = "https://cashier.invalid/test-notifications"
	const code = "weixin://wxpay/bizpayurl?pr=offline-fixture"
	expiry := time.Date(2026, 11, 8, 8, 15, 0, 0, time.UTC)
	lost := errors.New("simulated response lost")
	denied := errors.New("simulated merchant rejection")
	provider := &Wxpay{coreClient: &core.Client{}, config: map[string]string{
		"appId": "wx-local", "mchId": "12340001", "notifyUrl": notifyURL,
	}}
	tests := []struct {
		name   string
		expiry *time.Time
		answer *native.PrepayResponse
		err    error
		ready  bool
	}{
		{"original_qr", &expiry, &native.PrepayResponse{CodeUrl: core.String(code)}, nil, true},
		{"response_lost", &expiry, nil, lost, false},
		{"channel_rejection", &expiry, nil, denied, false},
		{"no_response", &expiry, nil, nil, false},
		{"no_code", &expiry, &native.PrepayResponse{}, nil, false},
		{"blank_code", &expiry, &native.PrepayResponse{CodeUrl: core.String(" ")}, nil, false},
		{"existing_caller_without_expiry", nil, &native.PrepayResponse{CodeUrl: core.String(code)}, nil, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			calls := 0
			wxpayNativePrepay = func(_ context.Context, _ native.NativeApiService, q native.PrepayRequest) (*native.PrepayResponse, *core.APIResult, error) {
				calls++
				if wxSV(q.OutTradeNo) != order || q.Amount == nil || q.Amount.Total == nil || *q.Amount.Total != 1031 ||
					wxSV(q.Amount.Currency) != "CNY" || wxSV(q.Appid) != "wx-local" || wxSV(q.Mchid) != "12340001" ||
					wxSV(q.NotifyUrl) != notifyURL || wxSV(q.Description) != "credits" {
					t.Fatal("渠道请求与原订单快照不一致")
				}
				if (q.TimeExpire == nil) != (test.expiry == nil) || q.TimeExpire != nil && !q.TimeExpire.Equal(*test.expiry) {
					t.Fatal("原订单有效期被重新计算")
				}
				return test.answer, nil, test.err
			}
			got, err := provider.CreatePayment(context.Background(), payment.CreatePaymentRequest{
				OrderID: order, Amount: "10.31", PaymentType: payment.TypeWxpay, Subject: "credits", ExpiresAt: test.expiry,
			})
			if calls != 1 {
				t.Fatalf("一次适配调用产生 %d 次渠道请求", calls)
			}
			if test.ready {
				if err != nil || got == nil || got.TradeNo != order || got.QRCode != code {
					t.Fatal("没有取得原单的呈现结果")
				}
			} else if err == nil || got != nil || test.err != nil && !errors.Is(err, test.err) {
				t.Fatal("渠道未知、拒绝或缺少支付码时错误地返回了可支付结果")
			}
		})
	}
}
