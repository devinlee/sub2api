//go:build meton_managed

package service

import (
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"testing"
)

/** TestManagedCheckoutExplicitEnvironment 两种合法部署之外全部关闭，不由空值或错误地址推定正式环境。 */
func TestManagedCheckoutExplicitEnvironment(t *testing.T) {
	for _, c := range []struct {
		environment, simulator string
		valid                  bool
	}{
		{"isolated", "http://127.0.0.1:12345", true}, {"live", "", true},
		{"", "", false}, {"production", "", false}, {"isolated", "", false},
		{"isolated", "https://api.mch.weixin.qq.com", false}, {"live", "http://127.0.0.1:12345", false},
		{"live", "https://api.mch.weixin.qq.com", false}, {"isolated", "http://localhost:12345", false},
	} {
		r := CheckoutPaymentRoute{Channel: "wechatpay", Environment: c.environment, Merchant: "12340001", App: "wx-local", Method: payment.TypeWxpay, Instance: 1, Simulator: c.simulator}
		if r.Valid() != c.valid {
			t.Fatalf("路由边界不符: %s %s", c.environment, c.simulator)
		}
		r.Instance = 0
		if r.Valid() {
			t.Fatal("缺少原商户实例仍被放行")
		}
	}
}
