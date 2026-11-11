//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type refundReviewKind uint8

const (
	payerReview refundReviewKind = iota
	alternativeReview
	cashDisputeReview
)

/** recordDispute 复用原审核材料的加密与去重；审核角色只有记录进度的权限，没有资金执行权。 */
func (s *refundPayerReviewStore) recordDispute(ctx context.Context, ref, op uuid.UUID, facts json.RawMessage, material []byte) error {
	return s.recordMaterial(ctx, ref, op, facts, material, cashDisputeReview)
}

/** syncCashDispute 使用当前原付款证明接续同一个争议；新归档事实先提交，再投影到来源。 */
func (w *refundSettlementWorker) syncCashDispute(ctx context.Context, tx *sql.Tx, trade, transaction string) (bool, error) {
	var origin json.RawMessage
	if err := cashSourceResult(ctx, w.source, &origin, "SELECT meton_ledger.prepare_cash_dispute_origin($1,$2,$3)", w.route, trade, transaction); err != nil {
		return false, err
	}
	var head struct {
		State string
		ID    uuid.UUID
	}
	if err := json.Unmarshal(origin, &head); err != nil {
		return false, err
	}
	if head.State == "original_unavailable" {
		return false, nil
	}
	if head.State != "ready" {
		return false, service.ErrMetonClosed
	}
	var reply []byte
	if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.bind_cash_dispute($1,$2)", w.route, string(origin)).Scan(&reply); err != nil {
		return false, err
	}
	if err := json.Unmarshal(reply, &head); err != nil {
		return false, err
	}
	if head.State == "recorded" {
		return true, nil
	}
	if head.State == "not_required" {
		return false, nil
	}
	if head.State != "bound" || head.ID == uuid.Nil {
		return false, service.ErrMetonClosed
	}
	if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.cash_dispute_result($1,$2)", w.route, head.ID).Scan(&reply); err != nil {
		return false, err
	}
	if err := json.Unmarshal(reply, &head); err != nil {
		return false, err
	}
	if head.State == "recorded" {
		return true, nil
	}
	if head.State != "dispute_proved" {
		return false, service.ErrMetonClosed
	}
	var result string
	if err := cashSourceResult(ctx, w.source, &result, "SELECT to_jsonb(meton_ledger.apply_cash_dispute_status($1,$2))", w.route, string(reply)); err != nil {
		return false, err
	}
	if result != "recorded" && result != "superseded" && result != "original_unavailable" {
		return false, service.ErrMetonClosed
	}
	return false, nil
}

/** syncRefundDispute 从原验真证明取付款身份，不能用退款号或当前登录账号猜一个资金对象。 */
func (w *refundSettlementWorker) syncRefundDispute(ctx context.Context, tx *sql.Tx, proof []byte) (bool, error) {
	type envelope struct {
		Cash struct{ Order, Transaction string }
	}
	var p struct {
		Facts struct {
			Envelope envelope
			Proposal struct{ Envelope envelope }
		}
	}
	if err := json.Unmarshal(proof, &p); err != nil {
		return false, err
	}
	e := p.Facts.Envelope
	if e.Cash.Order == "" {
		e = p.Facts.Proposal.Envelope
	}
	if e.Cash.Order == "" || e.Cash.Transaction == "" {
		return false, service.ErrMetonClosed
	}
	return w.syncCashDispute(ctx, tx, e.Cash.Order, e.Cash.Transaction)
}
