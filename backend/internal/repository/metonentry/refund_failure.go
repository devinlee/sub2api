//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
)

/** finishVerifiedFailure 复用原回调解密和签名复验，确认来源观察与截点外发送者退还均已提交，才释放这一笔。 */
func (w *purchaseWorker) finishVerifiedFailure(ctx context.Context, tx *sql.Tx, claim purchaseClaim, proof *purchaseProof, basis []byte) purchaseOutcome {
	route := string(w.n.wire)
	if _, err := tx.ExecContext(ctx, "SELECT meton_inbox.capture_refund_terminal($1,$2,$3,$4,$5)", route, claim.receipt, claim.hash, claim.lease, basis); err != nil {
		return purchaseOutcome{"retry", "refund_terminal_unconfirmed"}
	}
	// 原收件继续保留旧订单的签名材料，只有带完整历史交接和分配凭证的维护入口能归还其预扣。
	var historical struct {
		Cutoff        string `json:"legacyCutoff"`
		ManagedRefund string `json:"managedHistoricalRefund"`
	}
	if json.Unmarshal(proof.Origin, &historical) != nil {
		return purchaseOutcome{"review", "invalid_refund_origin"}
	}
	if historical.Cutoff != "" {
		return purchaseOutcome{"review", "historical_refund_recorded"}
	}
	if historical.ManagedRefund != "" {
		// 渠道原件已入归档。旧付款没有当前收银台订单，交由原退款结清者按截点判断。
		return purchaseOutcome{"posted", "managed_historical_refund_recorded"}
	}
	observed := w.applyRefund(ctx, proof)
	if observed.state == "retry" || proof.Notice.State != "CLOSED" {
		return observed
	}
	var receipt []byte
	if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.original_refund_failure($1,$2,$3,$4)", route, claim.receipt, claim.hash, claim.lease).Scan(&receipt); err != nil {
		return purchaseOutcome{"retry", "refund_failure_unconfirmed"}
	}
	var step struct{ State string }
	if json.Unmarshal(receipt, &step) != nil {
		return purchaseOutcome{"retry", "refund_failure_unconfirmed"}
	}
	switch step.State {
	case "review":
		return purchaseOutcome{"review", "refund_failure_review"}
	case "retry":
		return purchaseOutcome{"retry", "refund_failure_pending"}
	case "proved":
		var release struct{ State string }
		err := w.sourceResult(ctx, &release, "SELECT jsonb_build_object('state',meton_ledger.apply_verified_refund_failure($1,$2)) WHERE meton_ledger.notification_system_id()=$3",
			route, string(receipt), w.n.cfg.SourceSystem)
		if err != nil {
			return purchaseOutcome{"retry", "refund_release_unconfirmed"}
		}
		if release.State == "released" {
			return purchaseOutcome{"posted", "refund_closed_released"}
		}
		return purchaseOutcome{"review", "refund_release_review"}
	default:
		return purchaseOutcome{"retry", "refund_failure_unconfirmed"}
	}
}
