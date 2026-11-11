//go:build meton_managed

package metonentry

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type originalCashReviewJob struct {
	Receipt, Lease uuid.UUID
	Digest         string
	Order          string
	Transaction    string
}

/** nextCashReview 将无退款申请的强制返还送回原付款；归档保持原交易锁，来源自行复验账号和当前代次。 */
func (w *refundSettlementWorker) nextCashReview(ctx context.Context) (bool, error) {
	var job *originalCashReviewJob
	if err := cashSourceResult(ctx, w.archive, &job, "SELECT coalesce(meton_inbox.claim_external_cash_review($1),'null'::jsonb)", w.route); err != nil || job == nil {
		return false, err
	}
	hash, err := hex.DecodeString(job.Digest)
	if err != nil || len(hash) != 32 || job.Receipt == uuid.Nil || job.Lease == uuid.Nil {
		return true, service.ErrMetonClosed
	}
	for pass := 0; pass < 4; pass++ {
		recorded := false
		err = withRefundArchive(ctx, w.archive, func(tx *sql.Tx) error {
			var origin []byte
			if err := w.source.QueryRowContext(ctx, "SELECT coalesce(meton_ledger.original_cash_review_origin($1,$2,$3),'null'::jsonb)",
				w.route, job.Order, job.Transaction).Scan(&origin); err != nil {
				return err
			}
			result := "original_unavailable"
			if !bytes.Equal(origin, []byte("null")) {
				var proof []byte
				if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.original_cash_review_result($1,$2,$3,$4,$5)",
					w.route, job.Receipt, hash, job.Lease, string(origin)).Scan(&proof); err != nil {
					return err
				}
				var reply struct{ State string }
				if err := json.Unmarshal(proof, &reply); err != nil {
					return err
				}
				result = "retry"
				if reply.State == "review" {
					if err := cashSourceResult(ctx, w.source, &result, "SELECT to_jsonb(meton_ledger.record_original_cash_review($1,$2))",
						w.route, string(proof)); err != nil {
						return err
					}
					needsCommit, err := w.syncCashDispute(ctx, tx, job.Order, job.Transaction)
					if err != nil {
						return err
					}
					if needsCommit {
						recorded = true
						return nil
					}
				}
			}
			var finished bool
			if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.finish_external_cash_review($1,$2,$3,$4,$5)",
				w.route, job.Receipt, hash, job.Lease, result).Scan(&finished); err != nil {
				return err
			}
			if !finished {
				return service.ErrMetonClosed
			}
			return nil
		})
		if err != nil || !recorded {
			return true, err
		}
	}
	return true, nil
}
