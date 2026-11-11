package payment

/** OriginalRefundTarget 固定一次退款所属的原商户、实付及分次退款号。退款金额和实付上限均以分表示。 */
type OriginalRefundTarget struct {
	Merchant             string `json:"merchant"`
	App                  string `json:"app"`
	Order                string `json:"order"`
	Transaction          string `json:"transaction"`
	RefundOrder          string `json:"refundOrder"`
	Total                int64  `json:"total"`
	PayerTotal           int64  `json:"payerTotal"`
	PayerTotalUnrecorded bool   `json:"payerTotalUnrecorded,omitempty"`
	RefundFen            int64  `json:"refundFen"`
}
