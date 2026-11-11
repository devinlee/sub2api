package payment

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
)

var ErrInvalidCashNotice = errors.New("invalid payment notification")
var ErrCashNoticeConflict = errors.New("payment notification conflict")

/** CashNotice 只承载验真后的资金字段。验签时间、签名密钥和投递原文另存，不参与资金身份。 */
type CashNotice struct {
	Delivery      string `json:"delivery"`
	Kind          string `json:"kind"`
	State         string `json:"state"`
	Merchant      string `json:"merchant"`
	App           string `json:"app,omitempty"`
	Order         string `json:"order"`
	Transaction   string `json:"transaction"`
	Total         int64  `json:"total"`
	PayerTotal    int64  `json:"payerTotal"`
	Currency      string `json:"currency,omitempty"`
	PayerCurrency string `json:"payerCurrency,omitempty"`
	OccurredAt    string `json:"occurredAt,omitempty"`
	RefundOrder   string `json:"refundOrder,omitempty"`
	RefundID      string `json:"refundID,omitempty"`
	RefundFen     *int64 `json:"refundFen,omitempty"`
	PayerRefund   *int64 `json:"payerRefund,omitempty"`
}

/** CashQueryProof 保存签名 GET 的原字节与查单目标。渠道没有投递号，内部引用只用于查单证明去重。 */
type CashQueryProof struct {
	OrderState string
	Notice     *CashNotice
	Raw        []byte
	Headers    http.Header
	PublicKey  string
	Target     string
}

func (n CashNotice) QueryReference() string {
	raw, _ := json.Marshal([]string{n.Merchant, n.Order, n.Transaction})
	sum := sha256.Sum256(raw)
	return "q-" + hex.EncodeToString(sum[:])
}
