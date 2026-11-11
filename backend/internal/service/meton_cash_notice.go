package service

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"

	"github.com/Wei-Shaw/sub2api/internal/payment"
)

const NativeCashWebhook = "/api/v1/payment/webhook/wxpay"
const PublicCashWebhook = "/callbacks/payment/wxpay"

type CashNoticeStore interface {
	RecordNotice(context.Context, *payment.CashNotice, []byte, http.Header, string) error
}

type IsolatedExternalReturnStore interface {
	RecordIsolatedExternalReturn(context.Context, *payment.ExternalCashReturn, []byte, http.Header, string) error
}

type MetonCashNotifications struct {
	Route                   CheckoutPaymentRoute
	Callback                *url.URL
	Payments                *PaymentConfigService
	Store                   CashNoticeStore
	IsolatedExternalReturns bool
}

/** Receive 从受信部署选取唯一商户。重复通知也先验签，再依原商户号在独立收件库确认。 */
func (s *MetonCashNotifications) Receive(ctx context.Context, raw []byte, signature http.Header) error {
	// 装配已拒绝正式环境的测试事件；运行入口仍复验，避免绕过装配的调用启用模拟资金事实。
	if s == nil || s.Callback == nil || s.Payments == nil || s.Store == nil || !s.Route.Valid() || s.IsolatedExternalReturns && s.Route.Environment != "isolated" {
		return ErrMetonClosed
	}
	channel, err := s.Payments.checkoutWxpay(ctx, s.Route, s.Callback.String())
	if err != nil {
		return ErrMetonClosed
	}
	// 事件名只选择验真分支，不能提供身份或金额授权。未开启的部署仍由原通知验证器拒绝。
	var event struct {
		Event string `json:"event_type"`
	}
	if s.IsolatedExternalReturns && s.Route.Environment == "isolated" && json.Unmarshal(raw, &event) == nil &&
		(event.Event == payment.IsolatedChargebackEvent || event.Event == payment.IsolatedReversalEvent) {
		store, ok := s.Store.(IsolatedExternalReturnStore)
		if !ok {
			return ErrMetonClosed
		}
		facts, err := channel.VerifyIsolatedExternalReturn(ctx, raw, signature)
		if err != nil {
			return err
		}
		return store.RecordIsolatedExternalReturn(ctx, facts, raw, signature, channel.NoticePublicKey())
	}
	notice, err := channel.VerifyCashNotice(ctx, raw, signature)
	if err != nil {
		return err
	}
	return s.Store.RecordNotice(ctx, notice, raw, signature, channel.NoticePublicKey())
}

/** QueryOriginal 只读当次可信路由下的原商户单号。查询目标、金额与渠道结果均不接受用户自报。 */
func (s *MetonCashNotifications) QueryOriginal(ctx context.Context, trade string, fen int64) (*payment.CashQueryProof, error) {
	channel, err := s.Payments.checkoutWxpay(ctx, s.Route, s.Callback.String())
	if err != nil {
		return nil, err
	}
	return channel.OriginalCashQuery(ctx, trade, fen)
}

/** QueryStoppedOrder 与 CloseStoppedOrder 共用原托管商户。每次调用重新复验当前环境和实例。 */
func (s *MetonCashNotifications) QueryStoppedOrder(ctx context.Context, trade string, fen int64) (*payment.CashQueryProof, error) {
	channel, err := s.Payments.checkoutWxpay(ctx, s.Route, s.Callback.String())
	if err != nil {
		return nil, err
	}
	return channel.QueryCheckoutStop(ctx, trade, fen)
}

func (s *MetonCashNotifications) CloseStoppedOrder(ctx context.Context, trade string) (*payment.CashQueryProof, error) {
	channel, err := s.Payments.checkoutWxpay(ctx, s.Route, s.Callback.String())
	if err != nil {
		return nil, err
	}
	return channel.CloseCheckoutStop(ctx, trade)
}

/** SendOriginalRefund 由退款派发工作者在取得持久出站许可后调用，沿受控部署解析支付实例。 */
func (s *MetonCashNotifications) SendOriginalRefund(ctx context.Context, original payment.OriginalRefundTarget) (*payment.CashQueryProof, error) {
	channel, err := s.Payments.checkoutWxpay(ctx, s.Route, s.Callback.String())
	if err != nil {
		return nil, err
	}
	return channel.SendOriginalRefund(ctx, original)
}

/** QueryOriginalRefund 只联系同商户和应用的原退款号，重查无需发送权限。 */
func (s *MetonCashNotifications) QueryOriginalRefund(ctx context.Context, original payment.OriginalRefundTarget) (*payment.CashQueryProof, error) {
	channel, err := s.Payments.checkoutWxpay(ctx, s.Route, s.Callback.String())
	if err != nil {
		return nil, err
	}
	return channel.QueryOriginalRefund(ctx, original)
}
