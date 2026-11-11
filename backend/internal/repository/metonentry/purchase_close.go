//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type stopClaim struct {
	originalPaymentQuery
	Version  int64
	Dispatch *uuid.UUID
}
type stopResult struct {
	State    string
	Version  int64
	Dispatch *uuid.UUID
}

/** stopNextOriginal 每次从原单 GET 开始。只有首次确认未付才会获得发送许可，任何提交不确定都由下次 GET 接续。 */
func (w *purchaseWorker) stopNextOriginal(ctx context.Context) (bool, error) {
	tx, err := w.openStopArchive(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	wire := string(w.n.wire)
	var claim *stopClaim
	err = w.sourceResult(ctx, &claim, "SELECT coalesce(meton_ledger.claim_order_stop($1,$2),'null'::jsonb)", wire, w.closeWindow)
	if err != nil {
		return false, err
	}
	if claim == nil {
		return false, tx.Commit()
	}
	if claim.Intent == uuid.Nil || claim.Marker == uuid.Nil || claim.Token == uuid.Nil || claim.Version < 2 || claim.PriceFen <= 0 ||
		claim.Order == "" || len(claim.ParamsHash) != 64 {
		return true, service.ErrMetonClosed
	}
	proof, queryErr := w.channel.QueryStoppedOrder(ctx, claim.Order, claim.PriceFen)
	outcome := "query_unknown"
	if queryErr == nil && proof != nil {
		switch proof.OrderState {
		case "NOTPAY":
			outcome = "unpaid"
		case "USERPAYING":
			outcome = "paying"
		case "CLOSED":
			outcome = "channel_closed"
		case "SUCCESS":
			state, err := w.saveOriginalQuery(ctx, tx, &claim.originalPaymentQuery, proof)
			if err != nil {
				return true, err
			}
			if state == "evidence" {
				outcome = "paid"
			}
		}
	}
	var digest []byte
	if outcome != "query_unknown" {
		digest, err = w.saveStopProof(ctx, tx, claim, outcome, proof)
		if err != nil {
			return true, err
		}
	}
	if err = tx.Commit(); err != nil {
		return true, err
	}
	result, err := w.advanceStop(ctx, claim, claim.Version, outcome, nil, digest)
	if err != nil || result.State != "send" {
		return true, err
	}
	if outcome != "unpaid" || claim.Dispatch != nil || result.Dispatch == nil || *result.Dispatch == uuid.Nil || result.Version <= claim.Version {
		return true, service.ErrMetonClosed
	}
	return true, w.sendOrderClose(ctx, claim, result, digest)
}

/** 独立库在当前恢复代次锁住本渠道处理权；旧工作者不能根据历史连接继续发出命令。 */
func (w *purchaseWorker) openStopArchive(ctx context.Context) (*sql.Tx, error) {
	tx, err := w.archive.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err == nil {
		_, err = tx.ExecContext(ctx, "SELECT meton_inbox.lock_purchase_consumer($1)", string(w.n.wire))
	}
	if err != nil {
		tx.Rollback()
		return nil, err
	}
	return tx, nil
}

func (w *purchaseWorker) advanceStop(ctx context.Context, claim *stopClaim, version int64, outcome string, ticket *uuid.UUID, digest []byte) (stopResult, error) {
	var result stopResult
	// lib/pq 会把传入的空字节切片编码为零长度的 bytea。未取得签名材料时应发送 SQL NULL，保留上一份证明。
	var evidence any
	if len(digest) != 0 {
		evidence = digest
	}
	err := w.sourceResult(ctx, &result, "SELECT meton_ledger.advance_order_stop($1,$2,$3,$4,$5,$6,$7,$8)",
		string(w.n.wire), claim.Intent, claim.Marker, claim.Token, version, outcome, ticket, evidence)
	return result, err
}

/** 已验渠道材料按原意图、经济参数及结果保存。更换签名材料不会再产生一次外发许可。 */
func (w *purchaseWorker) saveStopProof(ctx context.Context, tx *sql.Tx, claim *stopClaim, outcome string, proof *payment.CashQueryProof) ([]byte, error) {
	basis, err := json.Marshal(map[string]any{"intent": claim.Intent, "marker": claim.Marker, "trade": claim.Order,
		"paramsHash": claim.ParamsHash, "priceFen": claim.PriceFen, "outcome": outcome, "target": proof.Target})
	if err != nil {
		return nil, err
	}
	digest, sealed, err := w.n.sealPaymentProof("order_stop", claim.Order, proof.Notice, basis, proof.Raw, proof.Headers, proof.PublicKey, proof.Target)
	if err != nil {
		return nil, err
	}
	var stored bool
	err = tx.QueryRowContext(ctx, "SELECT meton_inbox.record_order_stop_proof($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)", string(w.n.wire),
		claim.Intent, claim.Marker, claim.Order, claim.ParamsHash, outcome, digest, proof.Headers.Get("Wechatpay-Serial"), w.n.cfg.KeyRef, sealed).Scan(&stored)
	if err != nil {
		return nil, err
	}
	if !stored {
		return nil, service.ErrMetonClosed
	}
	return digest, nil
}

func (w *purchaseWorker) sendOrderClose(ctx context.Context, claim *stopClaim, result stopResult, unpaidDigest []byte) error {
	// 来源还原到较早截点时可能再产生内部票据。外部库以原商户单号去重，提交结果未知时不发送。
	tx, err := w.openStopArchive(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var first bool
	err = tx.QueryRowContext(ctx, "SELECT meton_inbox.take_order_close($1,$2,$3,$4,$5,$6,$7)", string(w.n.wire),
		claim.Intent, claim.Marker, claim.Order, claim.ParamsHash, result.Dispatch, unpaidDigest).Scan(&first)
	if err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	if !first {
		_, err = w.advanceStop(ctx, claim, result.Version, "close_unknown", result.Dispatch, nil)
		return err
	}
	guard, err := w.openStopArchive(ctx)
	if err != nil {
		return err
	}
	defer guard.Rollback()
	source, err := w.source.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return err
	}
	defer source.Rollback()
	var current bool
	if _, err = source.ExecContext(ctx, "SET LOCAL synchronous_commit=on"); err != nil {
		return err
	}
	err = source.QueryRowContext(ctx, "SELECT meton_ledger.current_order_close($1,$2,$3,$4,$5,$6)", string(w.n.wire),
		claim.Intent, claim.Marker, claim.Token, result.Version, result.Dispatch).Scan(&current)
	if err != nil || !current {
		return err
	}
	proof, closeErr := w.channel.CloseStoppedOrder(ctx, claim.Order)
	outcome := "close_unknown"
	var digest []byte
	if closeErr == nil && proof != nil && proof.OrderState == "CLOSED" {
		outcome = "close_accepted"
		digest, err = w.saveStopProof(ctx, guard, claim, outcome, proof)
		if err != nil {
			return err
		}
	}
	if err = guard.Commit(); err != nil {
		return err
	}
	if err = source.Commit(); err != nil {
		return err
	}
	_, err = w.advanceStop(ctx, claim, result.Version, outcome, result.Dispatch, digest)
	return err
}
