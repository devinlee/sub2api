//go:build !meton_managed

package provider

import (
	"context"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/payment"
)

/** 普通构建没有 Meton 隔离现金协议；保留同形拒绝端口，不能因环境变量而启用模拟回执。 */
func (w *Wxpay) VerifyIsolatedExternalReturn(context.Context, []byte, http.Header) (*payment.ExternalCashReturn, error) {
	return nil, payment.ErrInvalidCashNotice
}
