//go:build meton_managed

package provider

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
)

type managedNativeStub func(*http.Request) (*http.Response, error)

func (f managedNativeStub) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

/** TestManagedNativeTransportBoundary 只运行内存传输，不访问真实商户或本机服务。 */
func TestManagedNativeTransportBoundary(t *testing.T) {
	trade := strings.Repeat("a", 32)
	native := "https://" + managedWxpayHost + "/v3/pay/transactions/native"
	calls := 0
	lost := managedNativeStub(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host != managedWxpayHost || r.URL.Scheme != "https" {
			t.Fatal("正式目标被改写")
		}
		return nil, io.ErrUnexpectedEOF
	})
	live := checkoutLiveNative{transport: lost}
	for _, c := range []struct {
		method, target string
		allow          bool
	}{
		{"POST", native, true},
		{"GET", "https://" + managedWxpayHost + "/v3/pay/transactions/out-trade-no/" + trade + "?mchid=12340001", true},
		{"POST", "https://" + managedWxpayHost + "/v3/pay/transactions/out-trade-no/" + trade + "/close", true},
		{"POST", strings.Replace(native, "https:", "http:", 1), false},
		{"POST", strings.Replace(native, managedWxpayHost, "127.0.0.1:12345", 1), false},
		{"POST", native + "?extra=1", false},
		{"POST", native + "?", false},
		{"POST", native + "#fragment", false},
		{"POST", strings.Replace(native, managedWxpayHost, "user@"+managedWxpayHost, 1), false},
		{"GET", "https://" + managedWxpayHost + "/v3/certificates", false},
		{"POST", "https://" + managedWxpayHost + refundPath, false},
		{"GET", "https://" + managedWxpayHost + "/v3/pay/transactions/out-trade-no/" + trade + "?mchid=1&mchid=2", false},
		{"GET", "https://" + managedWxpayHost + "/v3/pay/transactions/out-trade-no/" + trade + "?mchid=1&", false},
	} {
		r, err := http.NewRequest(c.method, c.target, nil)
		if err != nil {
			t.Fatal(err)
		}
		before := calls
		_, _ = live.RoundTrip(r)
		if (calls == before+1) != c.allow {
			t.Fatalf("路由边界不符: %s %s", c.method, c.target)
		}
	}
	r, _ := http.NewRequest("POST", native, nil)
	r.Host = "other.invalid"
	before := calls
	if _, err := live.RoundTrip(r); err == nil || calls != before {
		t.Fatal("额外 Host 覆盖未拒绝")
	}
	if _, err := live.RoundTrip(nil); err == nil {
		t.Fatal("空请求未拒绝")
	}
	if _, err := (checkoutLocalNative{target: managedWxpayHost}).RoundTrip(r); err == nil {
		t.Fatal("模拟器不可成为正式域名")
	}

	// 第一次发送已经丢失应答；相同实例第二次调用也必须停在传输前。
	r, _ = http.NewRequest("POST", "https://"+managedWxpayHost+refundPath, strings.NewReader("{}"))
	wire := &refundWire{method: "POST", path: refundPath, remote: lost}
	before = calls
	if _, err := wire.RoundTrip(r); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatal("没有保留未知发送结果")
	}
	if _, err := wire.RoundTrip(r); err == nil || calls != before+1 {
		t.Fatal("退款发生第二次发送")
	}
	mixed := &refundWire{method: "POST", path: refundPath, remote: lost, local: "127.0.0.1:12345"}
	if _, err := mixed.RoundTrip(r); err == nil || calls != before+1 {
		t.Fatal("退款环境混用未拒绝")
	}
}

/** managedNativeKeys 仅生成当前用例的密钥，既有商户配置和私有目录均不读取。 */
func managedNativeKeys(t *testing.T) (map[string]string, *rsa.PrivateKey) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	public, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"appId": "wx-local", "mchId": "12340001", "apiV3Key": strings.Repeat("k", 32), "certSerial": "TEST-MERCHANT",
		"publicKeyId": "PUB_KEY_ID_TEST", "notifyUrl": "https://cash.invalid/callbacks/payment/wxpay",
		"privateKey": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})),
		"publicKey":  string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: public}))}, key
}

/** TestManagedNativeLiveSignedFlow 真实 SDK 经内存正式传输取回签名结果；未知和坏签名不能生成付款或退款成功事实。 */
func TestManagedNativeLiveSignedFlow(t *testing.T) {
	cfg, key := managedNativeKeys(t)
	w, err := NewLiveCheckoutWxpay("1", cfg)
	if err != nil {
		t.Fatal(err)
	}
	route, ok := w.checkoutClient.Transport.(checkoutLiveNative)
	if !ok {
		t.Fatal("未装配正式路由")
	}
	transport, ok := route.transport.(*http.Transport)
	if !ok || transport.Proxy != nil || !transport.DisableKeepAlives || transport.TLSClientConfig != nil && transport.TLSClientConfig.InsecureSkipVerify ||
		w.checkoutClient.Timeout <= 0 || w.checkoutClient.CheckRedirect(nil, nil) != http.ErrUseLastResponse {
		t.Fatal("正式传输保护不同")
	}
	trade, refund := strings.Repeat("a", 32), "R"+strings.Repeat("b", 32)
	target := payment.OriginalRefundTarget{Merchant: cfg["mchId"], App: cfg["appId"], Order: trade, Transaction: "4200000001",
		RefundOrder: refund, Total: 1000, PayerTotal: 1000, RefundFen: 200}
	posts, gets, creates := 0, 0, 0
	badSignature := false
	stub := managedNativeStub(func(r *http.Request) (*http.Response, error) {
		if !managedWxpayTarget(r) || !strings.HasPrefix(r.Header.Get("Authorization"), "WECHATPAY2-SHA256-RSA2048 ") {
			t.Fatal("SDK 未按正式请求签名")
		}
		body := `{"code_url":"weixin://wxpay/test"}`
		switch r.Method + " " + r.URL.Path {
		case "POST /v3/pay/transactions/native":
			creates++
		case "POST " + refundPath:
			posts++
			var sent map[string]any
			if json.NewDecoder(r.Body).Decode(&sent) != nil || sent["out_refund_no"] != refund || sent["transaction_id"] != target.Transaction {
				t.Fatal("未沿原退款号发送")
			}
			return nil, io.ErrUnexpectedEOF
		case "GET " + refundPath + "/" + refund:
			gets++
			body = fmt.Sprintf(`{"refund_id":"503000001","out_refund_no":%q,"transaction_id":%q,"out_trade_no":%q,"status":"SUCCESS","create_time":"2026-11-11T01:00:00+08:00","success_time":"2026-11-11T01:00:01+08:00","amount":{"total":1000,"refund":200,"payer_total":1000,"payer_refund":200,"currency":"CNY"}}`, refund, target.Transaction, trade)
		default:
			t.Fatal("超出当前正式传输范围")
		}
		stamp := strconv.FormatInt(time.Now().Unix(), 10)
		digest := sha256.Sum256([]byte(stamp + "\nnonce\n" + body + "\n"))
		signature, e := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
		if e != nil {
			t.Fatal(e)
		}
		if badSignature {
			signature[0] ^= 1
		}
		headers := http.Header{}
		headers.Set("Wechatpay-Timestamp", stamp)
		headers.Set("Wechatpay-Nonce", "nonce")
		headers.Set("Wechatpay-Serial", cfg["publicKeyId"])
		headers.Set("Wechatpay-Signature", base64.StdEncoding.EncodeToString(signature))
		headers.Set("Content-Type", "application/json")
		return &http.Response{StatusCode: 200, Header: headers, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	})
	w.checkoutClient.Transport = checkoutLiveNative{transport: stub}
	ctx := context.Background()
	created, err := w.CreatePayment(ctx, payment.CreatePaymentRequest{OrderID: trade, Amount: "10.00", Subject: "test", PaymentType: payment.TypeWxpay})
	if err != nil || created == nil || created.TradeNo != trade || creates != 1 {
		t.Fatalf("正式适配未取回原订单: %v", err)
	}
	if proof, err := w.SendOriginalRefund(ctx, target); err == nil || proof != nil || posts != 1 {
		t.Fatal("丢失应答被误认退款成功或自动重发")
	}
	proof, err := w.QueryOriginalRefund(ctx, target)
	if err != nil || proof == nil || proof.Notice == nil || proof.Notice.RefundOrder != refund || proof.OrderState != "SUCCESS" || posts != 1 || gets != 1 {
		t.Fatalf("未按原号查询退款: %v", err)
	}
	badSignature = true
	if proof, err := w.QueryOriginalRefund(ctx, target); err == nil || proof != nil || posts != 1 {
		t.Fatal("坏签名产生了退款证明")
	}
	if _, err := w.VerifyIsolatedExternalReturn(ctx, []byte(`{}`), http.Header{}); err == nil {
		t.Fatal("正式实例接受了模拟事件")
	}
	// 已有退款号的合法字符会被 SDK 编码，仍须查询原号，不能为此补造新退款。
	badSignature = false
	refund = "legacy|refund_1"
	target.RefundOrder = refund
	proof, err = w.QueryOriginalRefund(ctx, target)
	if err != nil || proof == nil || proof.Notice == nil || proof.Notice.RefundOrder != refund || posts != 1 || gets != 3 {
		t.Fatalf("历史退款号不能按原号查询: %v", err)
	}

	// 重定向响应即结束；既不跟随官方其他路径，也不改走模拟器。
	redirectCalls := 0
	redirect := &http.Client{Transport: managedNativeStub(func(r *http.Request) (*http.Response, error) {
		redirectCalls++
		return &http.Response{StatusCode: 307, Header: http.Header{"Location": []string{"https://other.invalid/"}}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	}), CheckRedirect: w.checkoutClient.CheckRedirect}
	u, _ := url.Parse("https://" + managedWxpayHost + "/v3/pay/transactions/native")
	r := &http.Request{Method: "POST", URL: u, Header: http.Header{}, Body: http.NoBody}
	response, err := redirect.Do(r)
	if err != nil || response.StatusCode != 307 || redirectCalls != 1 {
		t.Fatal("跟随了重定向")
	}
	response.Body.Close()
}
