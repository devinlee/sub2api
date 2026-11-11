//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type recoveredRefundClaim struct {
	Mode                  string
	Refund, Lease         uuid.UUID
	Owner, Scope, Request json.RawMessage
	Permit                string
}
type recoveredLookup struct {
	State, Lookup string
	Envelope      json.RawMessage
	QueryUntil    time.Time
}

/** recoveredNext 只从新版来源领取旧单的查询。没有上代独立归档或原账号交接链时，不能通过换节点补发。 */
func (w *refundDispatcher) recoveredNext(ctx context.Context) (bool, error) {
	var claim *recoveredRefundClaim
	err := cashSourceResult(ctx, w.source, &claim, "SELECT coalesce(meton_ledger.claim_recovered_refund_query($1),'null'::jsonb)", string(w.receiver.wire))
	if err != nil || claim == nil {
		return false, err
	}
	if claim.Mode == "review" {
		return true, nil
	}
	if claim.Mode != "recovered" || claim.Refund == uuid.Nil || claim.Lease == uuid.Nil || len(claim.Permit) != 64 {
		return true, service.ErrMetonClosed
	}
	var auth recoveredLookup
	err = w.archiveTx(ctx, func(tx *sql.Tx) error {
		var raw []byte
		if e := tx.QueryRowContext(ctx, "SELECT meton_inbox.authorize_recovered_refund_lookup($1,$2,$3)", string(claim.Scope), string(claim.Request), claim.Permit).Scan(&raw); e != nil {
			return e
		}
		return json.Unmarshal(raw, &auth)
	})
	if err != nil {
		return true, err
	}
	state := auth.State
	switch state {
	case "review", "evidence":
	case "ready":
		var old refundEnvelope
		var valid struct{ ValidUntil time.Time }
		if json.Unmarshal(auth.Envelope, &old) != nil || json.Unmarshal(claim.Scope, &valid) != nil || len(auth.Lookup) != 64 ||
			old.Cash.Merchant != w.receiver.cfg.Route.Merchant || old.Cash.App != w.receiver.cfg.Route.App || auth.QueryUntil.After(old.QueryUntil) ||
			old.Cash.RefundOrder != "R"+strings.ReplaceAll(claim.Refund.String(), "-", "") {
			return true, service.ErrMetonClosed
		}
		old.QueryUntil = auth.QueryUntil
		if valid.ValidUntil.Before(old.QueryUntil) {
			old.QueryUntil = valid.ValidUntil
		}
		job := refundJob{Refund: claim.Refund, Lease: claim.Lease, Owner: claim.Owner, Envelope: auth.Envelope, Material: refundGrantMaterial{Scope: claim.Scope}, Lookup: auth.Lookup}
		state, err = w.query(ctx, &job, old)
		if err != nil {
			return true, err
		}
	default:
		return true, service.ErrMetonClosed
	}
	var saved bool
	err = cashSourceResult(ctx, w.source, &saved, "SELECT to_jsonb(meton_ledger.finish_recovered_refund_query($1,$2,$3,$4))", string(claim.Owner), claim.Refund, claim.Lease, state)
	if err == nil && !saved {
		err = service.ErrMetonClosed
	}
	return true, err
}
