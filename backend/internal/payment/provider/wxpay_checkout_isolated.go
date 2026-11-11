package provider

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/wechatpay-apiv3/wechatpay-go/core"
	"github.com/wechatpay-apiv3/wechatpay-go/core/auth/validators"
	"github.com/wechatpay-apiv3/wechatpay-go/core/auth/verifiers"
	"github.com/wechatpay-apiv3/wechatpay-go/services/payments/native"
	"github.com/wechatpay-apiv3/wechatpay-go/utils"
)

/** IsCheckoutSimulator 仅接受显式端口的 IPv4 回环根地址。SDK 仍签名并复核应答。 */
func IsCheckoutSimulator(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
		return false
	}
	n, err := strconv.Atoi(u.Port())
	return err == nil && n > 0 && n <= 65535 && raw == "http://127.0.0.1:"+strconv.Itoa(n)
}

type checkoutLocalNative struct{ target string }

var checkoutOriginalQuery = regexp.MustCompile(`^/v3/pay/transactions/out-trade-no/[0-9a-f]{32}$`)
var checkoutOriginalClose = regexp.MustCompile(`^/v3/pay/transactions/out-trade-no/[0-9a-f]{32}/close$`)

func (t checkoutLocalNative) RoundTrip(r *http.Request) (*http.Response, error) {
	if !IsCheckoutSimulator("http://"+t.target) || !managedCheckoutRequest(r) {
		return nil, errors.New("unexpected native simulator request")
	}
	local := r.Clone(r.Context())
	local.URL.Scheme = "http"
	local.URL.Host = t.target
	local.Host = t.target
	return checkoutLoopbackTransport.RoundTrip(local)
}

/** FindCheckoutOrder 只报告签名响应是否属于原商户、应用、交易、币种和整数金额。付款及到账事实仍由资金流程处理。 */
func (w *Wxpay) FindCheckoutOrder(ctx context.Context, trade string, fen int64) bool {
	if w.checkoutClient == nil {
		return false
	}
	tx, err := w.nativeOrder(ctx, trade)
	if err != nil || wxSV(tx.OutTradeNo) != trade || wxSV(tx.Appid) != w.config["appId"] || wxSV(tx.Mchid) != w.config["mchId"] ||
		tx.Amount == nil || tx.Amount.Total == nil || *tx.Amount.Total != fen || wxSV(tx.Amount.Currency) != "CNY" {
		return false
	}
	switch wxSV(tx.TradeState) {
	case "NOTPAY", "USERPAYING", "SUCCESS", "REFUND", "CLOSED", "REVOKED", "PAYERROR":
		return true
	default:
		return false
	}
}

var checkoutLoopbackTransport = &http.Transport{Proxy: nil, DisableKeepAlives: true}

/** OriginalCashQuery 必须有实际签名响应和完整的原交易、现金分及付款时间，才产生可履约的查询证明。 */
func (w *Wxpay) OriginalCashQuery(ctx context.Context, trade string, fen int64) (*payment.CashQueryProof, error) {
	proof, err := w.QueryCheckoutStop(ctx, trade, fen)
	if err != nil {
		return nil, err
	}
	switch proof.OrderState {
	case "SUCCESS":
		return proof, nil
	case "NOTPAY", "USERPAYING":
		return nil, nil
	default:
		return nil, errors.New("original query requires reconciliation")
	}
}

/** QueryCheckoutStop 保留每一种已验原单状态的签名材料。只有 SUCCESS 会同时产生原支付的资金证据。 */
func (w *Wxpay) QueryCheckoutStop(ctx context.Context, trade string, fen int64) (*payment.CashQueryProof, error) {
	if w.checkoutClient == nil {
		return nil, payment.ErrInvalidCashNotice
	}
	tx, result, err := w.nativeOrderResult(ctx, trade)
	if result != nil && result.Response != nil && result.Response.Body != nil {
		defer result.Response.Body.Close()
	}
	if err != nil || tx == nil || result == nil || result.Request == nil || result.Response == nil || result.Response.Body == nil {
		return nil, errors.New("original query unavailable")
	}
	if wxSV(tx.OutTradeNo) != trade || wxSV(tx.Mchid) != w.config["mchId"] || wxSV(tx.Appid) != w.config["appId"] ||
		tx.Amount == nil || tx.Amount.Total == nil || *tx.Amount.Total <= 0 || wxSV(tx.Amount.Currency) != "CNY" ||
		*tx.Amount.Total != fen && wxSV(tx.TradeState) != "SUCCESS" {
		return nil, payment.ErrInvalidCashNotice
	}
	target := result.Request.URL
	if result.Request.Method != "GET" || target == nil || target.Scheme != "https" || target.Host != "api.mch.weixin.qq.com" ||
		target.EscapedPath() != "/v3/pay/transactions/out-trade-no/"+trade || target.RawQuery != "mchid="+url.QueryEscape(w.config["mchId"]) ||
		result.Response.StatusCode != http.StatusOK {
		return nil, payment.ErrInvalidCashNotice
	}
	raw, err := io.ReadAll(io.LimitReader(result.Response.Body, (1<<20)+1))
	if err != nil || len(raw) == 0 || len(raw) > 1<<20 {
		return nil, payment.ErrInvalidCashNotice
	}
	h, err := checkoutSignature(result.Response.Header)
	if err != nil {
		return nil, err
	}
	proof := &payment.CashQueryProof{OrderState: wxSV(tx.TradeState), Raw: raw, Headers: h, PublicKey: w.NoticePublicKey(), Target: target.String()}
	switch proof.OrderState {
	case "NOTPAY", "USERPAYING", "CLOSED":
		return proof, nil
	case "SUCCESS":
	default:
		return nil, errors.New("original query requires reconciliation")
	}
	stamp, err := time.Parse(time.RFC3339Nano, wxSV(tx.SuccessTime))
	if err != nil || wxSV(tx.TradeType) != "NATIVE" || !noticeReference.MatchString(wxSV(tx.TransactionId)) || tx.Amount.PayerTotal == nil ||
		*tx.Amount.PayerTotal < 0 || *tx.Amount.PayerTotal > *tx.Amount.Total || wxSV(tx.Amount.PayerCurrency) != "CNY" {
		return nil, payment.ErrInvalidCashNotice
	}
	proof.Notice = &payment.CashNotice{Kind: "payment", State: "SUCCESS", Merchant: w.config["mchId"], App: w.config["appId"], Order: trade, Transaction: wxSV(tx.TransactionId),
		Total: *tx.Amount.Total, PayerTotal: *tx.Amount.PayerTotal, Currency: "CNY", PayerCurrency: "CNY", OccurredAt: stamp.UTC().Format(time.RFC3339Nano)}
	return proof, nil
}

/** CloseCheckoutStop 仅托管路由可请求，必须收到原单的已验签 204 空响应才能确认渠道关单。 */
func (w *Wxpay) CloseCheckoutStop(ctx context.Context, trade string) (*payment.CashQueryProof, error) {
	path := "/v3/pay/transactions/out-trade-no/" + trade + "/close"
	if w.checkoutClient == nil || !checkoutOriginalClose.MatchString(path) {
		return nil, payment.ErrInvalidCashNotice
	}
	client, err := w.ensureClient()
	if err != nil {
		return nil, err
	}
	service := native.NativeApiService{Client: client}
	result, err := service.CloseOrder(ctx, native.CloseOrderRequest{OutTradeNo: core.String(trade), Mchid: core.String(w.config["mchId"])})
	if result != nil && result.Response != nil && result.Response.Body != nil {
		defer result.Response.Body.Close()
	}
	if err != nil || result == nil || result.Request == nil || result.Request.URL == nil || result.Response == nil ||
		result.Response.StatusCode != http.StatusNoContent || result.Response.Body == nil || result.Request.Method != "POST" ||
		result.Request.URL.String() != "https://api.mch.weixin.qq.com"+path {
		return nil, errors.New("original close unresolved")
	}
	body, err := io.ReadAll(io.LimitReader(result.Response.Body, 1))
	if err != nil || len(body) != 0 {
		return nil, payment.ErrInvalidCashNotice
	}
	h, err := checkoutSignature(result.Response.Header)
	if err != nil {
		return nil, err
	}
	return &payment.CashQueryProof{OrderState: "CLOSED", Raw: body, Headers: h, PublicKey: w.NoticePublicKey(), Target: result.Request.URL.String()}, nil
}

func checkoutSignature(headers http.Header) (http.Header, error) {
	h := http.Header{}
	for _, k := range []string{"Wechatpay-Timestamp", "Wechatpay-Nonce", "Wechatpay-Signature", "Wechatpay-Serial"} {
		values := headers.Values(k)
		if len(values) != 1 || values[0] == "" || len(values[0]) > 4096 {
			return nil, payment.ErrInvalidCashNotice
		}
		h.Set(k, values[0])
	}
	return h, nil
}

/** NewIsolatedCheckoutWxpay 只改变本实例的发送目的地。回环不可达或重定向时停止，绝不回落到微信。 */
func NewIsolatedCheckoutWxpay(id string, cfg map[string]string, simulator string) (*Wxpay, error) {
	if !IsCheckoutSimulator(simulator) {
		return nil, errors.New("invalid checkout simulator")
	}
	w, err := NewWxpay(id, cfg)
	if err != nil {
		return nil, err
	}
	u, _ := url.Parse(simulator)
	w.checkoutClient = &http.Client{Transport: checkoutLocalNative{u.Host}, Timeout: 6 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	return w, nil
}

/** SDK 对非成功响应先返回 APIError。只有来源签名有效且明确拒绝的错误可以结束预下单。 */
func (w *Wxpay) verifiedCheckoutDecline(ctx context.Context, err error) bool {
	var e *core.APIError
	if !errors.As(err, &e) || e.StatusCode != http.StatusBadRequest && e.StatusCode != http.StatusForbidden ||
		len(e.Body) > 8192 || e.Code != "PARAM_ERROR" && e.Code != "NO_AUTH" && e.Code != "APPID_MCHID_NOT_MATCH" {
		return false
	}
	key, readErr := utils.LoadPublicKey(formatPEM(w.config["publicKey"], "PUBLIC KEY"))
	if readErr != nil {
		return false
	}
	v := validators.NewWechatPayResponseValidator(verifiers.NewSHA256WithRSAPubkeyVerifier(w.config["publicKeyId"], *key))
	return v.Validate(ctx, &http.Response{Header: e.Header, Body: io.NopCloser(strings.NewReader(e.Body))}) == nil
}
