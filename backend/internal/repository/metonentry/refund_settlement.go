//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type refundSettlementWorker struct {
	source, archive *sql.DB
	route           string
}

type refundSettlementJob struct {
	Refund, Token uuid.UUID
	Revision      int64
}

/** StartRefundSettlement 只给结清进程读取原现金证明及提交原账本的连接。 */
func StartRefundSettlement(path string, notices *service.MetonCashNotifications) (func(), error) {
	return StartRefundSettlementWithAlternative(path, "", notices)
}

/** StartRefundSettlementWithAlternative 可选装配本机替代退款，发送和来源结清继续使用不同受限连接。 */
func StartRefundSettlementWithAlternative(path, alternativePath string, notices *service.MetonCashNotifications) (func(), error) {
	if path == "" {
		if alternativePath != "" {
			return nil, service.ErrMetonClosed
		}
		return func() {}, nil
	}
	if notices == nil || !notices.Route.Valid() {
		return nil, service.ErrMetonClosed
	}
	n, ok := notices.Store.(*cashNoticeStore)
	if !ok {
		return nil, service.ErrMetonClosed
	}
	src, arc, closePools, err := openRefundDatabases(path)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, sourceRole, se := checkPoolPermissions(src, []string{"meton_ledger.notification_system_id()", "meton_ledger.refund_settlement_ready(jsonb)", "meton_ledger.resolve_original_refund(jsonb,uuid,jsonb)",
		"meton_ledger.original_cash_review_origin(jsonb,text,text)", "meton_ledger.record_original_cash_review(jsonb,jsonb)",
		"meton_ledger.prepare_cash_dispute_origin(jsonb,text,text)", "meton_ledger.apply_cash_dispute_status(jsonb,jsonb)",
		"meton_ledger.read_original_refund_aftercare(jsonb,uuid)", "meton_ledger.open_original_refund_aftercare(jsonb,uuid,text)",
		"meton_ledger.prepare_original_refund_aftercare(jsonb,uuid)", "meton_ledger.apply_original_refund_verification(jsonb,uuid,jsonb)",
		"meton_ledger.prepare_original_alternative(jsonb,uuid,jsonb)", "meton_ledger.prepare_original_alternative_stop(jsonb,uuid)",
		"meton_ledger.apply_original_alternative_decision(jsonb,uuid,jsonb)",
		"meton_ledger.original_alternative_cash_permit(jsonb,uuid,jsonb)", "meton_ledger.resolve_alternative_refund(jsonb,uuid,jsonb)", "meton_ledger.resolve_alternative_closed(jsonb,uuid,jsonb)"})
	system, archiveRole, ae := checkCashArchive(ctx, arc, []string{"meton_inbox.refund_settlement_ready(jsonb)", "meton_inbox.claim_refund_settlement(jsonb)",
		"meton_inbox.original_refund_cash_result(jsonb,uuid)", "meton_inbox.finish_refund_settlement(jsonb,uuid,bigint,uuid,text)",
		"meton_inbox.claim_external_cash_review(jsonb)", "meton_inbox.original_cash_review_result(jsonb,uuid,bytea,uuid,jsonb)",
		"meton_inbox.finish_external_cash_review(jsonb,uuid,bytea,uuid,text)",
		"meton_inbox.bind_cash_dispute(jsonb,jsonb)", "meton_inbox.cash_dispute_result(jsonb,uuid)",
		"meton_inbox.bind_original_refund_aftercare(jsonb,jsonb)", "meton_inbox.original_refund_aftercare_result(jsonb,uuid)",
		"meton_inbox.original_alternative_material(jsonb,uuid,uuid)", "meton_inbox.original_alternative_decision(jsonb,uuid)",
		"meton_inbox.decide_original_alternative(jsonb,jsonb,text)", "meton_inbox.claim_alternative_cash(jsonb)",
		"meton_inbox.finish_alternative_cash(jsonb,uuid,uuid,text)", "meton_inbox.prepare_alternative_cash(jsonb,uuid)", "meton_inbox.alternative_cash_result(jsonb,uuid)"})
	route := string(n.wire)
	var primary string
	var ready bool
	if se != nil || ae != nil || sourceRole == archiveRole || system != n.cfg.InboxSystem || !giftPoolSeparate(src) || !resultPoolPrivate(src) ||
		src.QueryRowContext(ctx, "SELECT meton_ledger.notification_system_id(),meton_ledger.refund_settlement_ready($1)", route).Scan(&primary, &ready) != nil ||
		!ready || primary != n.cfg.SourceSystem || arc.QueryRowContext(ctx, "SELECT meton_inbox.refund_settlement_ready($1)", route).Scan(&ready) != nil || !ready {
		closePools()
		return nil, service.ErrMetonClosed
	}
	worker := &refundSettlementWorker{source: src, archive: arc, route: route}
	alternative, err := openAlternativeCash(alternativePath, worker, n)
	if err != nil {
		closePools()
		return nil, err
	}
	nexts := []func(context.Context) (bool, error){worker.next, worker.nextCashReview}
	if alternative != nil {
		nexts = append(nexts, alternative.next)
	}
	lifetime, stop := context.WithCancel(context.Background())
	// 两类原现金工作各自有界领取，某笔缺来源时不能阻塞其他退款或让外部返还长期排在退款之后。
	var jobs sync.WaitGroup
	for _, next := range nexts {
		jobs.Add(1)
		go func() { defer jobs.Done(); runCashWorker(lifetime, next) }()
	}
	return func() {
		stop()
		jobs.Wait()
		if alternative != nil {
			alternative.sender.Close()
		}
		closePools()
	}, nil
}

/** next 在归档原付款锁内结清。现金已确认后即使来源或队列提交丢失，下一次工作仍只重读原退款。 */
func (w *refundSettlementWorker) next(ctx context.Context) (bool, error) {
	var job *refundSettlementJob
	if err := cashSourceResult(ctx, w.archive, &job, "SELECT coalesce(meton_inbox.claim_refund_settlement($1),'null'::jsonb)", w.route); err != nil || job == nil {
		return false, err
	}
	// 原现金、核验和替代选择各自先提交事实；有界接续这些提交，不在未提交状态下签证明。
	for pass := 0; pass < 5; pass++ {
		recorded := false
		err := withRefundArchive(ctx, w.archive, func(tx *sql.Tx) error {
			var raw []byte
			if err := tx.QueryRowContext(ctx, "SELECT coalesce(meton_inbox.alternative_cash_result($1,$2),meton_inbox.original_refund_cash_result($1,$2))", w.route, job.Refund).Scan(&raw); err != nil {
				return err
			}
			var reply struct{ State string }
			if err := json.Unmarshal(raw, &reply); err != nil {
				return err
			}
			if reply.State == "recorded" {
				recorded = true
				return nil
			}
			result := reply.State
			// 来源可能恢复到替代准备以前。先从独立库取回同一决定，再接现金或关闭；不重新审批、不调用付款渠道。
			if result == "alternative_success" || result == "alternative_review" || result == "alternative_closed" || result == "alternative_pending" {
				needsCommit, choice, err := w.advanceAlternative(ctx, tx, job.Refund, nil, false)
				if err != nil {
					return err
				}
				if needsCommit {
					recorded = true
					return nil
				}
				if choice != "reserved" {
					result = "retry"
				}
			}
			switch result {
			case "success_proved", "review", "alternative_success", "alternative_review", "alternative_closed":
				query := "SELECT to_jsonb(meton_ledger.resolve_original_refund($1,$2,$3))"
				if result == "alternative_success" || result == "alternative_review" {
					query = "SELECT to_jsonb(meton_ledger.resolve_alternative_refund($1,$2,$3))"
				}
				if result == "alternative_closed" {
					query = "SELECT to_jsonb(meton_ledger.resolve_alternative_closed($1,$2,$3))"
				}
				// 首次源事务只记现金，下一次源事务同时扣原批次和解除这笔占用。
				for commit := 0; commit < 2; commit++ {
					if err := cashSourceResult(ctx, w.source, &result, query, w.route, job.Refund, string(raw)); err != nil {
						return err
					}
					if result != "cash_confirmed" {
						break
					}
				}
				if result == "cash_confirmed" {
					result = "retry"
				}
			case "unbound":
				result = "original_unavailable"
			case "alternative_pending":
				result = "retry"
			case "pending", "closed_observed":
				// 先找回截点外原申请；否则窗口在恢复期间经过，会把“付款账户不可用”误建成另一种售后。
				needsCommit, err := w.syncAftercare(ctx, tx, job.Refund)
				if err != nil {
					return err
				}
				if needsCommit {
					recorded = true
					return nil
				}
				// 过了原路发送窗口也继续沿原退款保留权利；待核验申请不授予替代付款或释放原冻结。
				var aftercare struct{ State string }
				if err := cashSourceResult(ctx, w.source, &aftercare, "SELECT meton_ledger.open_original_refund_aftercare($1,$2,'window_elapsed')",
					w.route, job.Refund); err != nil {
					return err
				}
			default:
				result = "retry"
			}
			if result == "pending" || result == "closed_observed" || result == "review" {
				if result == "review" {
					needsCommit, err := w.syncRefundDispute(ctx, tx, raw)
					if err != nil {
						return err
					}
					if needsCommit {
						recorded = true
						return nil
					}
				}
				needsCommit, err := w.syncAftercare(ctx, tx, job.Refund)
				if err != nil {
					return err
				}
				if needsCommit {
					recorded = true
					return nil
				}
				needsCommit, _, err = w.advanceAlternative(ctx, tx, job.Refund, nil, false)
				if err != nil {
					return err
				}
				if needsCommit {
					recorded = true
					return nil
				}
			}
			var finished bool
			return tx.QueryRowContext(ctx, "SELECT meton_inbox.finish_refund_settlement($1,$2,$3,$4,$5)", w.route, job.Refund, job.Revision, job.Token, result).Scan(&finished)
		})
		if err != nil || !recorded {
			return true, err
		}
	}
	return true, nil
}
