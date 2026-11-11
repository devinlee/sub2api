package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"time"

	"github.com/Wei-Shaw/sub2api/ent/paymentproviderinstance"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/payment/provider"
	"github.com/boombuler/barcode/qr"
	"github.com/google/uuid"
)

/** CheckoutPaymentRoute 来自只读部署配置。环境显式选择，不能由会员请求或传输失败切换。 */
type CheckoutPaymentRoute struct {
	Channel     string `json:"channel"`
	Environment string `json:"environment"`
	Merchant    string `json:"merchant"`
	App         string `json:"app"`
	Method      string `json:"method"`
	Instance    int64  `json:"instance"`
	Simulator   string `json:"simulator"`
}

func (r CheckoutPaymentRoute) Valid() bool {
	if r.Channel != "wechatpay" || r.Method != payment.TypeWxpay || r.Merchant == "" || len(r.Merchant) > 128 ||
		r.App == "" || len(r.App) > 128 || r.Instance <= 0 {
		return false
	}
	switch r.Environment {
	case "isolated":
		return provider.IsCheckoutSimulator(r.Simulator)
	case "live":
		return r.Simulator == ""
	default:
		return false
	}
}

type CheckoutPaymentSender interface {
	CreatePayment(context.Context, payment.CreatePaymentRequest) (*payment.CreatePaymentResponse, error)
	FindCheckoutOrder(context.Context, string, int64) bool
}

/** findCheckoutOrder 遇到可能已经派发的原单，只查原商户号。普通账单、其他商户、已取得支付码的订单都不会联系渠道。 */
func (s *MetonCheckout) findCheckoutOrder(ctx context.Context, q *CheckoutRequest, item *CheckoutOrder) bool {
	r := s.Route
	if r == nil || s.Payments == nil || !q.WantCode || q.Browser == nil || item == nil || item.Attempt != "possibly_sent" || item.OutTradeNo == nil ||
		item.Channel != r.Channel || item.Environment != r.Environment || item.Merchant != r.Merchant || item.App != r.App || item.PaymentConfirmed || item.CashReview != nil ||
		item.CloseState != "" && item.CloseState != "open" {
		return false
	}
	channel, err := s.Payments.CheckoutPayment(ctx, *r)
	return err == nil && channel != nil && channel.FindCheckoutOrder(ctx, *item.OutTradeNo, item.PriceFen)
}

type CheckoutPaymentResolver interface {
	CheckoutPayment(context.Context, CheckoutPaymentRoute) (CheckoutPaymentSender, error)
}

/** CheckoutPayment 只从原指定实例解出一次配置。绑定和创建客户端使用同一份快照，调度器不能改选商户。 */
func (s *PaymentConfigService) CheckoutPayment(ctx context.Context, r CheckoutPaymentRoute) (CheckoutPaymentSender, error) {
	w, err := s.checkoutWxpay(ctx, r, "")
	if err != nil {
		return nil, err
	}
	return w, nil
}

/** checkoutWxpay 在同一配置快照中复核收件地址和商户，轮换后新通知必须按当版材料验真。 */
func (s *PaymentConfigService) checkoutWxpay(ctx context.Context, r CheckoutPaymentRoute, callback string) (*provider.Wxpay, error) {
	if s == nil || s.entClient == nil || !r.Valid() {
		return nil, ErrMetonClosed
	}
	inst, err := s.entClient.PaymentProviderInstance.Query().Where(paymentproviderinstance.IDEQ(r.Instance),
		paymentproviderinstance.EnabledEQ(true), paymentproviderinstance.ProviderKeyEQ(r.Method)).Select(paymentproviderinstance.FieldConfig).Only(ctx)
	if err != nil {
		return nil, ErrMetonClosed
	}
	cfg, err := s.decryptConfig(inst.Config)
	if err != nil || cfg["mchId"] != r.Merchant || cfg["appId"] != r.App {
		return nil, ErrMetonClosed
	}
	notify, err := url.Parse(cfg["notifyUrl"])
	if err != nil || notify.Scheme != "https" || notify.Hostname() == "" || notify.User != nil || notify.RawQuery != "" || notify.Fragment != "" ||
		callback != "" && cfg["notifyUrl"] != callback {
		return nil, ErrMetonClosed
	}
	if r.Environment == "live" {
		return provider.NewLiveCheckoutWxpay(strconv.FormatInt(r.Instance, 10), cfg)
	}
	return provider.NewIsolatedCheckoutWxpay(strconv.FormatInt(r.Instance, 10), cfg, r.Simulator)
}

type checkoutObservationStore interface {
	ObserveCheckoutPayment(context.Context, CheckoutOrigin, uuid.UUID, uuid.UUID, string, string) error
}

func checkoutDispatchWire(q *CheckoutRequest, r *CheckoutPaymentRoute) ([]byte, error) {
	return json.Marshal(struct {
		*CheckoutRequest
		Route *CheckoutPaymentRoute `json:"route"`
	}{q, r})
}

/** present 只消费已经提交的唯一派发票据。渠道超时或缺码保留「可能已发」，迟到的已验证回应只能写回这张票据。 */
func (s *MetonCheckout) present(ctx context.Context, q *CheckoutRequest, raw string, channel CheckoutPaymentSender) error {
	store, ok := s.Store.(checkoutObservationStore)
	var claim struct {
		Dispatch   uuid.UUID `json:"dispatch"`
		OutTradeNo string    `json:"outTradeNo"`
		Product    string    `json:"product"`
		PriceFen   int64     `json:"priceFen"`
		Currency   string    `json:"currency"`
		ExpiresAt  time.Time `json:"expiresAt"`
	}
	if !ok || decodeGift([]byte(raw), &claim) != nil || claim.Dispatch == uuid.Nil || claim.PriceFen != q.Selection.PriceFen ||
		claim.Currency != q.Selection.Currency || claim.Product != q.Selection.Product || len(claim.OutTradeNo) != 32 ||
		!claim.ExpiresAt.After(time.Now()) || ctx.Err() != nil {
		return ErrMetonClosed
	}
	call, cancel := context.WithDeadline(ctx, claim.ExpiresAt)
	defer cancel()
	reply, err := channel.CreatePayment(call, payment.CreatePaymentRequest{OrderID: claim.OutTradeNo,
		Amount: fmt.Sprintf("%d.%02d", claim.PriceFen/100, claim.PriceFen%100), Subject: claim.Product, PaymentType: s.Route.Method, ExpiresAt: &claim.ExpiresAt})
	kind, value := "qr", ""
	if errors.Is(err, payment.ErrNativePrepayDeclined) {
		kind, value = "declined", "channel_rejected"
	} else if err == nil && reply != nil && reply.TradeNo == claim.OutTradeNo && validNativePaymentCode(reply.QRCode) {
		value = reply.QRCode
	} else {
		return ErrMetonClosed
	}
	// 浏览器断开不能丢掉已取得的原渠道证明。保存操作只持有本次原单认领，始终有短截止。
	save, stop := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer stop()
	return store.ObserveCheckoutPayment(save, q.Origin, q.Intent, claim.Dispatch, kind, value)
}

func validNativePaymentCode(value string) bool {
	if len(value) == 0 || len(value) > 2048 {
		return false
	}
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "weixin" || u.Host != "wxpay" || u.Path != "/bizpayurl" || u.RawPath != "" || u.Fragment != "" || u.User != nil {
		return false
	}
	q, err := url.ParseQuery(u.RawQuery)
	return err == nil && len(q["pr"]) == 1 && q.Get("pr") != ""
}

/** CheckoutCode 只交付可绘制的黑白矩阵。普通账单与浏览器地址都无须携带支付链接。 */
type CheckoutCode struct {
	Side      int       `json:"side"`
	Bits      []byte    `json:"bits"`
	ExpiresAt time.Time `json:"expiresAt"`
}

func checkoutMatrix(value string) (*CheckoutCode, error) {
	if !validNativePaymentCode(value) {
		return nil, ErrMetonClosed
	}
	im, err := qr.Encode(value, qr.M, qr.Auto)
	if err != nil {
		return nil, ErrMetonClosed
	}
	n := im.Bounds().Dx()
	b := make([]byte, (n*n+7)/8)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			red, _, _, _ := im.At(x, y).RGBA()
			if red == 0 {
				k := y*n + x
				b[k/8] |= 1 << uint(7-k%8)
			}
		}
	}
	return &CheckoutCode{Side: n, Bits: b}, nil
}
