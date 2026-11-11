package payment

const IsolatedChargebackEvent = "METON.ISOLATED.CHARGEBACK"
const IsolatedReversalEvent = "METON.ISOLATED.REVERSAL"

/** ExternalCashReturn 只描述渠道已验真的原款返还事实，不接收账号、退款意图或余额。 */
type ExternalCashReturn struct {
	Format      int    `json:"format"`
	Kind        string `json:"kind"`
	Reference   string `json:"reference"`
	Order       string `json:"order"`
	Transaction string `json:"transaction"`
	Currency    string `json:"currency"`
	ReturnedFen string `json:"returnedFen"`
	OccurredAt  string `json:"occurredAt"`
}
