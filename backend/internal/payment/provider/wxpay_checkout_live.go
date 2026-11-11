package provider

import (
	"errors"
	"net/http"
	"net/url"
	"time"
)

const managedWxpayHost = "api.mch.weixin.qq.com"

/** managedWxpayTarget 拒绝重定向目标、额外主机覆盖和非规范 URL，避免签名与实际发送对象不同。 */
func managedWxpayTarget(r *http.Request) bool {
	return r != nil && r.URL != nil && r.URL.Scheme == "https" && r.URL.Host == managedWxpayHost &&
		(r.Host == "" || r.Host == managedWxpayHost) && r.URL.User == nil && r.URL.Opaque == "" &&
		!r.URL.ForceQuery && r.URL.Fragment == ""
}

/** managedCheckoutRequest 两种环境共用最小的下单、原号查询和关单范围，不开放通用支付代理。 */
func managedCheckoutRequest(r *http.Request) bool {
	if !managedWxpayTarget(r) {
		return false
	}
	path := r.URL.EscapedPath()
	if r.Method == http.MethodPost {
		return r.URL.RawQuery == "" && (path == "/v3/pay/transactions/native" || checkoutOriginalClose.MatchString(path))
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	return err == nil && r.Method == http.MethodGet && checkoutOriginalQuery.MatchString(path) &&
		len(query) == 1 && len(query["mchid"]) == 1 && query.Get("mchid") != "" &&
		r.URL.RawQuery == "mchid="+url.QueryEscape(query.Get("mchid"))
}

type checkoutLiveNative struct{ transport http.RoundTripper }

func (t checkoutLiveNative) RoundTrip(r *http.Request) (*http.Response, error) {
	if t.transport == nil || !managedCheckoutRequest(r) {
		return nil, errors.New("unexpected managed native request")
	}
	return t.transport.RoundTrip(r)
}

/** NewLiveCheckoutWxpay 不接收目标地址；只允许部署显式选中的正式商户，构造本身不产生网络请求。 */
func NewLiveCheckoutWxpay(id string, cfg map[string]string) (*Wxpay, error) {
	w, err := NewWxpay(id, cfg)
	if err != nil {
		return nil, err
	}
	// 不复用环境代理或现存连接。写请求失去应答由原任务查号，不能由传输层自动重发。
	w.checkoutClient = &http.Client{Transport: checkoutLiveNative{transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}},
		Timeout: 6 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	return w, nil
}
