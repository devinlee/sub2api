//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

/** save 按原商户退款号保存已验签的响应。原字节和签名用现有恢复密钥封存，来源只读取已提交的状态。 */
func (w *refundDispatcher) save(ctx context.Context, tx *sql.Tx, j *refundJob, method string, p *payment.CashQueryProof) (string, error) {
	if p == nil || len(p.Raw) == 0 || p.PublicKey == "" || p.Headers.Get("Wechatpay-Signature") == "" {
		return "", service.ErrMetonClosed
	}
	var reply struct {
		Number      string `json:"out_refund_no"`
		RefundID    string `json:"refund_id"`
		Order       string `json:"out_trade_no"`
		Transaction string `json:"transaction_id"`
		Status      string `json:"status"`
		Amount      struct {
			Total       *int64 `json:"total"`
			Payer       *int64 `json:"payer_total"`
			Refund      *int64 `json:"refund"`
			PayerRefund *int64 `json:"payer_refund"`
			Currency    string `json:"currency"`
		} `json:"amount"`
	}
	var e refundEnvelope
	if json.Unmarshal(j.Envelope, &e) != nil || json.Unmarshal(p.Raw, &reply) != nil || reply.RefundID == "" || reply.Status != p.OrderState ||
		reply.Order != e.Cash.Order || reply.Transaction != e.Cash.Transaction || reply.Number != e.Cash.RefundOrder ||
		reply.Amount.Total == nil || *reply.Amount.Total != e.Cash.Total || reply.Amount.Refund == nil || *reply.Amount.Refund != e.Cash.RefundFen ||
		reply.Amount.Payer == nil || reply.Amount.PayerRefund == nil || reply.Amount.Currency != "CNY" {
		return "", service.ErrMetonClosed
	}
	notice := &payment.CashNotice{Kind: "refund", State: p.OrderState, Merchant: e.Cash.Merchant, Order: reply.Order, Transaction: reply.Transaction,
		RefundOrder: reply.Number, RefundID: reply.RefundID, Total: *reply.Amount.Total, PayerTotal: *reply.Amount.Payer, RefundFen: reply.Amount.Refund, PayerRefund: reply.Amount.PayerRefund}
	if p.Notice != nil {
		notice.OccurredAt = p.Notice.OccurredAt
	}
	if method != http.MethodGet && method != http.MethodPost {
		return "", service.ErrMetonClosed
	}
	digest, sealed, err := w.receiver.sealPaymentProof("refund_dispatch_"+strings.ToLower(method), j.Refund.String(), notice, j.Envelope, p.Raw, p.Headers, p.PublicKey, p.Target)
	if err != nil {
		return "", err
	}
	fields, err := json.Marshal(map[string]any{"order": reply.Order, "transaction": reply.Transaction, "refundOrder": reply.Number, "refundID": reply.RefundID,
		"total": notice.Total, "payerTotal": notice.PayerTotal, "refundFen": *reply.Amount.Refund, "payerRefund": *reply.Amount.PayerRefund})
	if err != nil {
		return "", err
	}
	rawHash := sha256.Sum256(p.Raw)
	var state string
	if j.Lookup != "" {
		if method != http.MethodGet {
			return "", service.ErrMetonClosed
		}
		err = tx.QueryRowContext(ctx, "SELECT meton_inbox.record_recovered_refund_get($1,$2,$3,$4,$5,$6,$7,$8,$9)", string(j.Material.Scope), j.Refund,
			p.OrderState, rawHash[:], digest, string(fields), w.receiver.cfg.KeyRef, sealed, j.Lookup).Scan(&state)
		return state, err
	}
	err = tx.QueryRowContext(ctx, "SELECT meton_inbox.record_original_refund_transport($1,$2,$3,$4,$5,$6,$7,$8,$9)", string(j.Material.Scope), j.Refund, method,
		p.OrderState, rawHash[:], digest, string(fields), w.receiver.cfg.KeyRef, sealed).Scan(&state)
	return state, err
}
