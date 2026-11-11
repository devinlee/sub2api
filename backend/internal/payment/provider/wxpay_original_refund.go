package provider

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sync/atomic"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/wechatpay-apiv3/wechatpay-go/core"
	"github.com/wechatpay-apiv3/wechatpay-go/services/refunddomestic"
)

const refundPath = "/v3/refund/domestic/refunds"

var managedRefundNumber = regexp.MustCompile(`^R[0-9a-f]{32}$`)
var originalMerchantNumber = regexp.MustCompile(`^[A-Za-z0-9_|*@-]{1,64}$`)

// 一次操作只放行一种方法和一个目标。SDK 重试或重定向不能由查询变成再发退款。
type refundWire struct {
	method, path, local string
	remote              http.RoundTripper
	used                atomic.Bool
}

func (t *refundWire) RoundTrip(r *http.Request) (*http.Response, error) {
	// 历史退款号允许 | 等字符；SDK 负责 URL 编码，比较解码后的原路径才能继续只查原号。
	if !managedWxpayTarget(r) || r.Method != t.method || r.URL.Path != t.path || r.URL.RawQuery != "" ||
		(t.remote == nil && !IsCheckoutSimulator("http://"+t.local)) || (t.remote != nil && t.local != "") || !t.used.CompareAndSwap(false, true) {
		return nil, errors.New("unexpected original refund transmission")
	}
	if t.remote != nil {
		return t.remote.RoundTrip(r)
	}
	local := r.Clone(r.Context())
	local.URL.Scheme = "http"
	local.URL.Host = t.local
	local.Host = t.local
	return checkoutLoopbackTransport.RoundTrip(local)
}

/** originalRefundClient 只沿原托管环境构造单次客户端，不能借退款切换商户、环境或放宽收银台范围。 */
func (w *Wxpay) originalRefundClient(t payment.OriginalRefundTarget, method, path string) (*core.Client, error) {
	if w.checkoutClient == nil || w.config["mchId"] != t.Merchant || w.config["appId"] != t.App || !originalMerchantNumber.MatchString(t.Order) ||
		!noticeReference.MatchString(t.Transaction) || !originalMerchantNumber.MatchString(t.RefundOrder) || t.Total < 1 || t.PayerTotal < 0 ||
		t.PayerTotal > t.Total || t.PayerTotalUnrecorded && t.PayerTotal != 0 || t.RefundFen < 1 || t.RefundFen > t.Total {
		return nil, payment.ErrInvalidCashNotice
	}
	wire := &refundWire{method: method, path: path}
	switch route := w.checkoutClient.Transport.(type) {
	case checkoutLocalNative:
		if !IsCheckoutSimulator("http://" + route.target) {
			return nil, payment.ErrInvalidCashNotice
		}
		wire.local = route.target
	case checkoutLiveNative:
		if route.transport == nil {
			return nil, payment.ErrInvalidCashNotice
		}
		wire.remote = route.transport
	default:
		return nil, payment.ErrInvalidCashNotice
	}
	client, err := NewWxpay(w.instanceID, w.config)
	if err != nil {
		return nil, err
	}
	client.checkoutClient = &http.Client{Timeout: w.checkoutClient.Timeout, CheckRedirect: w.checkoutClient.CheckRedirect, Transport: wire}
	return client.ensureClient()
}

/** SendOriginalRefund 使用来源已经持久化的本笔退款号和原实付交易号。任何 HTTP 应答都不能在此结清现金。 */
func (w *Wxpay) SendOriginalRefund(ctx context.Context, t payment.OriginalRefundTarget) (*payment.CashQueryProof, error) {
	if !managedRefundNumber.MatchString(t.RefundOrder) {
		return nil, payment.ErrInvalidCashNotice
	}
	cb, err := url.Parse(w.config["notifyUrl"])
	if err != nil || cb.Scheme != "https" || cb.Hostname() == "" || cb.User != nil || cb.Fragment != "" || cb.RawQuery != "" {
		return nil, payment.ErrInvalidCashNotice
	}
	c, err := w.originalRefundClient(t, http.MethodPost, refundPath)
	if err != nil {
		return nil, err
	}
	service := refunddomestic.RefundsApiService{Client: c}
	res, reply, err := service.Create(ctx, refunddomestic.CreateRequest{TransactionId: core.String(t.Transaction),
		OutRefundNo: core.String(t.RefundOrder), NotifyUrl: core.String(cb.String()), Amount: &refunddomestic.AmountReq{
			Refund: core.Int64(t.RefundFen), Total: core.Int64(t.Total), Currency: core.String("CNY")}})
	return w.refundReply(t, http.MethodPost, refundPath, res, reply, err)
}

/** QueryOriginalRefund 只读原商户退款号。旧单缺号或查询不符都保持未知。 */
func (w *Wxpay) QueryOriginalRefund(ctx context.Context, t payment.OriginalRefundTarget) (*payment.CashQueryProof, error) {
	path := refundPath + "/" + t.RefundOrder
	c, err := w.originalRefundClient(t, http.MethodGet, path)
	if err != nil {
		return nil, err
	}
	service := refunddomestic.RefundsApiService{Client: c}
	res, reply, err := service.QueryByOutRefundNo(ctx, refunddomestic.QueryByOutRefundNoRequest{OutRefundNo: core.String(t.RefundOrder)})
	return w.refundReply(t, http.MethodGet, path, res, reply, err)
}

func (w *Wxpay) refundReply(t payment.OriginalRefundTarget, method, path string, res *refunddomestic.Refund, r *core.APIResult, err error) (*payment.CashQueryProof, error) {
	if r != nil && r.Response != nil && r.Response.Body != nil {
		defer r.Response.Body.Close()
	}
	if err != nil || r == nil || r.Request == nil || r.Request.URL == nil || r.Request.Method != method || r.Request.URL.Host != "api.mch.weixin.qq.com" ||
		r.Request.URL.Scheme != "https" || r.Request.URL.Path != path || r.Request.URL.RawQuery != "" || r.Response == nil || r.Response.Body == nil || r.Response.StatusCode != http.StatusOK ||
		res == nil || res.Amount == nil || wxSV(res.OutRefundNo) != t.RefundOrder || wxSV(res.OutTradeNo) != t.Order || wxSV(res.TransactionId) != t.Transaction ||
		!noticeReference.MatchString(wxSV(res.RefundId)) || res.Status == nil || res.CreateTime == nil {
		return nil, payment.ErrInvalidCashNotice
	}
	a := res.Amount
	if wxSV(a.Currency) != "CNY" || a.Total == nil || *a.Total != t.Total || a.Refund == nil || *a.Refund != t.RefundFen ||
		a.PayerTotal == nil || *a.PayerTotal < 0 || *a.PayerTotal > t.Total || !t.PayerTotalUnrecorded && *a.PayerTotal != t.PayerTotal ||
		a.PayerRefund == nil || *a.PayerRefund < 0 || *a.PayerRefund > t.RefundFen || *a.PayerRefund > *a.PayerTotal {
		return nil, payment.ErrInvalidCashNotice
	}
	state := string(*res.Status)
	if state != "SUCCESS" && state != "CLOSED" && state != "ABNORMAL" && state != "PROCESSING" {
		return nil, payment.ErrInvalidCashNotice
	}
	raw, err := io.ReadAll(io.LimitReader(r.Response.Body, (1<<20)+1))
	if err != nil || len(raw) == 0 || len(raw) > 1<<20 {
		return nil, payment.ErrInvalidCashNotice
	}
	headers, err := checkoutSignature(r.Response.Header)
	if err != nil {
		return nil, err
	}
	proof := &payment.CashQueryProof{OrderState: state, Raw: raw, Headers: headers, PublicKey: w.NoticePublicKey(), Target: r.Request.URL.String()}
	if method == http.MethodPost || state == "PROCESSING" {
		return proof, nil
	}
	notice := &payment.CashNotice{Kind: "refund", State: state, Merchant: t.Merchant, Order: t.Order, Transaction: t.Transaction,
		Total: t.Total, PayerTotal: *a.PayerTotal, RefundOrder: t.RefundOrder, RefundID: *res.RefundId, RefundFen: a.Refund, PayerRefund: a.PayerRefund}
	if state == "SUCCESS" {
		if res.SuccessTime == nil || res.SuccessTime.Before(*res.CreateTime) {
			return nil, payment.ErrInvalidCashNotice
		}
		notice.OccurredAt = res.SuccessTime.UTC().Format(time.RFC3339Nano)
	}
	proof.Notice = notice
	return proof, nil
}
