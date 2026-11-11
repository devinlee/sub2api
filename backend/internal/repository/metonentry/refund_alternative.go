//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

/** advanceAlternative 沿原工作者接续已批准的同一份额；独立决定已提交才交回来源，不调用支付渠道。 */
func (w *refundSettlementWorker) advanceAlternative(ctx context.Context, tx *sql.Tx, ref uuid.UUID, approval *uuid.UUID, abandon bool) (bool, string, error) {
	var material []byte
	var head struct{ State string }
	if abandon {
		if err := cashSourceResult(ctx, w.source, (*json.RawMessage)(&material), "SELECT meton_ledger.prepare_original_alternative_stop($1,$2)", w.route, ref); err != nil {
			return false, "", err
		}
		if err := json.Unmarshal(material, &head); err != nil {
			return false, "", err
		}
		if head.State != "source_ready" {
			return false, head.State, nil
		}
	} else {
		if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.original_alternative_material($1,$2,$3)", w.route, ref, approval).Scan(&material); err != nil {
			return false, "", err
		}
		if err := json.Unmarshal(material, &head); err != nil {
			return false, "", err
		}
		if head.State == "recorded" {
			return true, head.State, nil
		}
		if head.State != "approval_ready" && head.State != "decision_proved" {
			return false, head.State, nil
		}
		if head.State == "approval_ready" {
			approvalProof := string(material)
			for pass := 0; pass < 2; pass++ {
				if err := cashSourceResult(ctx, w.source, (*json.RawMessage)(&material), "SELECT meton_ledger.prepare_original_alternative($1,$2,$3)", w.route, ref, approvalProof); err != nil {
					return false, "", err
				}
				if err := json.Unmarshal(material, &head); err != nil {
					return false, "", err
				}
				if head.State != "recorded" {
					break
				}
			}
			if head.State != "source_ready" {
				return head.State == "recorded", head.State, nil
			}
		}
	}
	if head.State == "source_ready" {
		want := "reserve"
		if abandon {
			want = "abandon"
		}
		var decided []byte
		if err := tx.QueryRowContext(ctx, "SELECT meton_inbox.decide_original_alternative($1,$2,$3)", w.route, string(material), want).Scan(&decided); err != nil {
			return false, "", err
		}
		material = decided
		if err := json.Unmarshal(material, &head); err != nil {
			return false, "", err
		}
	}
	if head.State == "recorded" {
		return true, head.State, nil
	}
	if head.State != "decision_proved" {
		return false, head.State, nil
	}
	var result string
	if err := cashSourceResult(ctx, w.source, &result, "SELECT to_jsonb(meton_ledger.apply_original_alternative_decision($1,$2,$3))", w.route, ref, string(material)); err != nil {
		return false, "", err
	}
	if result != "reserved" && result != "abandoned" && result != "recovery_review" {
		return false, "", service.ErrMetonClosed
	}
	return false, result, nil
}

/** approve 保存独立审核员的批准材料；仍须由原协调流程复验来源和截点外事实。 */
func (s *refundPayerReviewStore) approve(ctx context.Context, ref, op uuid.UUID, facts json.RawMessage, material []byte) error {
	return s.recordMaterial(ctx, ref, op, facts, material, alternativeReview)
}
