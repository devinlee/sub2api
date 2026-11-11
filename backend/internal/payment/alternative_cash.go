package payment

import (
	"encoding/json"
	"regexp"
)

// AlternativeCashTarget 是已批准的原退款目标；首版只启用本机模拟协议，不复用微信退款身份。
type AlternativeCashTarget struct {
	Rail            string `json:"rail"`
	Environment     string `json:"environment"`
	Merchant        string `json:"merchant"`
	Order           string `json:"order"`
	BeneficiaryHash string `json:"beneficiaryHash"`
	Currency        string `json:"currency"`
	Fen             int64  `json:"fen"`
}

var alternativeReference = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,120}$`)
var alternativeBeneficiary = regexp.MustCompile(`^[0-9a-f]{64}$`)

/** Valid 只接受明确的隔离协议和原整分金额，不在适配器里换汇或补造收款人。 */
func (p AlternativeCashTarget) Valid() bool {
	return p.Rail == "meton-isolated-transfer" && p.Environment == "isolated" && p.Currency == "CNY" &&
		alternativeReference.MatchString(p.Merchant) && alternativeReference.MatchString(p.Order) &&
		alternativeBeneficiary.MatchString(p.BeneficiaryHash) && p.Fen > 0
}

type AlternativeCashFact struct {
	Payment     AlternativeCashTarget `json:"payment"`
	State       string                `json:"state"`
	Transaction string                `json:"transaction"`
}

/** Valid 受理、查无、失败和成功分开；成功必须有替代渠道的独立现金编号。 */
func (f AlternativeCashFact) Valid() bool {
	return f.Payment.Valid() && (f.State == "pending" || f.State == "failed" || f.State == "not_found" || f.State == "closed" && f.Transaction == "" ||
		f.State == "succeeded" && alternativeReference.MatchString(f.Transaction))
}

// AlternativeCashProof 保存可独立重验的响应字节、公钥和签名，不保存签名私钥。
type AlternativeCashProof struct {
	Fact      AlternativeCashFact `json:"fact"`
	Raw       []byte              `json:"raw"`
	Statement []byte              `json:"statement"`
	Signature []byte              `json:"signature"`
	PublicKey []byte              `json:"publicKey"`
}

/** AlternativeCashStatement 把签名绑定到请求方法、路径、随机挑战、时间和原字节，防止跨请求或 POST/GET 混用。 */
func AlternativeCashStatement(kind, method, path, nonce, stamp string, status int, body []byte) []byte {
	// HTTP 空正文在不同读写端可能是 nil 或空切片，签名只按线上零字节计算。
	if len(body) == 0 {
		body = []byte{}
	}
	b, _ := json.Marshal([]any{"meton.isolated.alternative.v1", kind, method, path, nonce, stamp, status, body})
	return b
}
