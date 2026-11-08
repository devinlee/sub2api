//go:build meton_managed

package metonresult

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
)

// AcceptedTextPrice 的字段取自来源事务已固定的原预占。
type AcceptedTextPrice struct {
	Environment, Source, Model, Unit, Version string
}

/** NewPricedSourceResponse 在开始读取前固定用户费率，原观察和后续供应对账共用同一笔原请求。 */
func NewPricedSourceResponse(response *http.Response, protocol, model string, codex bool, price AcceptedTextPrice, finish func(Snapshot)) (*Reader, error) {
	r, err := NewSourceResponse(response, protocol, model, codex, finish)
	if err == nil {
		r.customerTokenPrice = r.codexStream && r.sse && model == "gpt-5.6-sol" &&
			price == (AcceptedTextPrice{Environment: "s1-isolated", Source: "s1-managed", Model: model,
				Unit: "sample-credit", Version: "s2-60885-text-v2"})
	}
	return r, err
}

/** rememberAttribution 只取供应原字段字节的指纹，归属内容不进入用户费用或运行日志。 */
func (r *Reader) rememberAttribution(raw []byte) {
	digest := sha256.Sum256(raw)
	r.supplierAttribution = hex.EncodeToString(digest[:])
}

/** SupplierAttributionDigest 供终局回调关联已经持久化的原请求、供应响应及整流摘要。 */
func (r *Reader) SupplierAttributionDigest() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.supplierAttribution
}
