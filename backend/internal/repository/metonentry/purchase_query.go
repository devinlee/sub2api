//go:build meton_managed

package metonentry

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type originalPaymentQuery struct {
	Intent     uuid.UUID `json:"intent"`
	Marker     uuid.UUID `json:"marker"`
	Token      uuid.UUID `json:"token"`
	Order      string    `json:"order"`
	PriceFen   int64     `json:"priceFen"`
	ParamsHash string    `json:"paramsHash"`
}

/** queryNextOriginal 先认领可能已发的原单，只做 GET。没有取得合法支付终态时保留原单，不重新下单。 */
func (w *purchaseWorker) queryNextOriginal(ctx context.Context) (bool, error) {
	wire := string(w.n.wire)
	tx, err := w.archive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return false, err
	}
	if _, err = tx.ExecContext(ctx, "SELECT meton_inbox.lock_purchase_consumer($1)", wire); err != nil {
		return false, err
	}
	var claim *originalPaymentQuery
	err = w.sourceResult(ctx, &claim, "SELECT coalesce(meton_ledger.claim_original_cash_query($1,$2),'null'::jsonb)", wire, w.queryWindow)
	if err != nil {
		return false, err
	}
	if claim == nil {
		return false, tx.Commit()
	}
	if claim.Intent == uuid.Nil || claim.Marker == uuid.Nil || claim.Token == uuid.Nil || claim.Order == "" || claim.PriceFen <= 0 {
		return true, service.ErrMetonClosed
	}
	state := "unknown"
	proof, err := w.channel.QueryOriginal(ctx, claim.Order, claim.PriceFen)
	switch {
	case errors.Is(err, payment.ErrInvalidCashNotice):
		state = "unknown"
	case err != nil:
		state = "unknown"
	case proof == nil:
		state = "pending"
	default:
		state, err = w.saveOriginalQuery(ctx, tx, claim, proof)
		if err != nil {
			return true, err
		}
	}
	// 若独立提交的响应丢失，不在来源库提前记为已取得证明。到期后仍只认领原单查询，原证明也可独立处理。
	if err = tx.Commit(); err != nil {
		return true, err
	}
	var finished bool
	err = w.sourceResult(ctx, &finished, "SELECT meton_ledger.finish_original_cash_query($1,$2,$3,$4,$5)", wire, claim.Intent, claim.Marker, claim.Token, state)
	if err != nil {
		return true, err
	}
	if !finished {
		return true, service.ErrMetonClosed
	}
	return true, nil
}

func (w *purchaseWorker) saveOriginalQuery(ctx context.Context, tx *sql.Tx, claim *originalPaymentQuery, p *payment.CashQueryProof) (string, error) {
	if p.Notice == nil || p.Notice.Delivery != "" || p.Notice.Order != claim.Order || p.Notice.Total <= 0 {
		return "review", nil
	}
	facts, err := json.Marshal(p.Notice)
	if err != nil {
		return "", err
	}
	cfg := w.n.cfg
	origin, err := w.n.originalCashBasis(ctx, facts)
	if err != nil {
		return "", err
	}
	var owner struct {
		Intent, SourceMarker uuid.UUID
		ParamsHash           string
		PriceFen             int64
	}
	if json.Unmarshal(origin, &owner) != nil || owner.Intent != claim.Intent || owner.SourceMarker != claim.Marker || owner.ParamsHash != claim.ParamsHash ||
		owner.PriceFen != claim.PriceFen {
		return "review", nil
	}
	ref := p.Notice.QueryReference()
	digest, sealed, err := w.n.sealPaymentProof("payment_query", ref, p.Notice, origin, p.Raw, p.Headers, p.PublicKey, p.Target)
	if err != nil {
		return "", err
	}
	signedFacts, err := json.Marshal([]any{cfg.Route.Channel, cfg.Route.Environment, cfg.Route.Merchant, cfg.Route.App, p.Notice})
	if err != nil {
		return "", err
	}
	signedHash := sha256.Sum256(signedFacts)
	var state string
	err = tx.QueryRowContext(ctx, "SELECT meton_inbox.accept_payment_query($1,$2,$3,$4,$5,$6,$7) WHERE meton_inbox.system_id()=$8",
		string(w.n.wire), ref, digest, signedHash[:], p.Headers.Get("Wechatpay-Serial"), cfg.KeyRef, sealed, cfg.InboxSystem).Scan(&state)
	if err != nil {
		return "", err
	}
	switch state {
	case "accepted":
		return "evidence", nil
	case "conflict":
		return "review", nil
	default:
		return "", service.ErrMetonClosed
	}
}
