package service

import (
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"time"

	"github.com/google/uuid"
)

const MemberDisputeMaterialLimit = 512 * 1024

/** CheckoutBodyLimit 只有材料提交可使用较大报文，普通订单与查询继续沿原上限。 */
func CheckoutBodyLimit(action string) int {
	if action == "dispute_submit" {
		return 768 * 1024
	}
	return 8192
}

var disputeActions = [...]string{"dispute_submit", "dispute_status"}

func IsCheckoutDispute(action string) bool { return slices.Contains(disputeActions[:], action) }

type MemberDisputeRequest struct {
	ID       uuid.UUID `json:"id"`
	Expected int64     `json:"expected,omitempty"`
	Kind     string    `json:"kind,omitempty"`
	Material []byte    `json:"material,omitempty"`
}
type MemberDisputeSubmission struct {
	Operation    uuid.UUID `json:"operation"`
	Kind         string    `json:"kind"`
	Revision     int64     `json:"revision"`
	MaterialHash string    `json:"materialHash"`
}
type MemberDisputeResult struct {
	State          string                   `json:"state"`
	ID             uuid.UUID                `json:"id"`
	Revision       int64                    `json:"revision"`
	Phase          string                   `json:"phase"`
	FinancialState string                   `json:"financialState"`
	Finding        *string                  `json:"finding"`
	Submission     *MemberDisputeSubmission `json:"submission"`
}

/** parseMemberDispute 严格分开当前会员与浏览器交接用途，材料只随本次提交进入加密归档。 */
func (s *MetonCheckout) parseMemberDispute(raw []byte, action string, creation, intent uuid.UUID) (*CheckoutRequest, error) {
	var q struct {
		Version    int                   `json:"version"`
		Origin     CheckoutOrigin        `json:"origin"`
		Desktop    CheckoutSubject       `json:"desktop"`
		Intent     uuid.UUID             `json:"intent"`
		ValidUntil time.Time             `json:"validUntil"`
		Dispute    *MemberDisputeRequest `json:"memberDispute"`
	}
	if len(raw) > CheckoutBodyLimit(action) || decodeGift(raw, &q) != nil || q.Dispute == nil || q.Dispute.ID == uuid.Nil {
		return nil, ErrCheckoutDenied
	}
	r := &CheckoutRequest{Version: q.Version, Origin: q.Origin, Desktop: q.Desktop, Intent: q.Intent, ValidUntil: q.ValidUntil, memberDispute: q.Dispute}
	if !r.validSession(s.Source, creation, intent) {
		return nil, ErrCheckoutDenied
	}
	d := q.Dispute
	if action == "dispute_submit" {
		if d.Expected < 1 || !slices.Contains([]string{"appeal", "supplement"}, d.Kind) || len(d.Material) < 1 || len(d.Material) > MemberDisputeMaterialLimit {
			return nil, ErrCheckoutDenied
		}
	} else if action != "dispute_status" || d.Expected != 0 || d.Kind != "" || d.Material != nil {
		return nil, ErrCheckoutDenied
	}
	return r, nil
}

/** memberDisputeReceipt 只交付原案公开进度；查无原提交不代表先前写入已确定失败。 */
func memberDisputeReceipt(receipt *CheckoutReceipt, q *CheckoutRequest, action, raw string) (*CheckoutReceipt, error) {
	var v MemberDisputeResult
	if decodeGift([]byte(raw), &v) != nil || v.ID != q.memberDispute.ID || v.Revision < 1 || v.FinancialState != "restricted" ||
		!slices.Contains([]string{"observed", "stale", "phase_conflict"}, v.State) ||
		!slices.Contains([]string{"pending_review", "reviewing", "awaiting_material", "reviewed_restricted"}, v.Phase) ||
		v.Finding != nil && !slices.Contains([]string{"cash_difference_confirmed", "external_return_confirmed", "ownership_unresolved", "payer_amount_unknown", "liability_pending"}, *v.Finding) {
		return nil, ErrMetonClosed
	}
	if a := v.Submission; a != nil {
		if a.Operation != q.Intent || a.Revision < 1 || a.Revision > v.Revision || !refundVersion.MatchString(a.MaterialHash) ||
			!slices.Contains([]string{"appeal", "supplement"}, a.Kind) || v.State != "observed" {
			return nil, ErrMetonClosed
		}
		if action == "dispute_submit" {
			hash := sha256.Sum256(q.memberDispute.Material)
			if a.Kind != q.memberDispute.Kind || a.MaterialHash != hex.EncodeToString(hash[:]) || a.Revision != q.memberDispute.Expected+1 {
				return nil, ErrMetonClosed
			}
		}
	} else if action == "dispute_submit" && v.State == "observed" {
		return nil, ErrMetonClosed
	}
	if action == "dispute_status" && v.State != "observed" {
		return nil, ErrMetonClosed
	}
	receipt.Purpose, receipt.State, receipt.Dispute = "dispute", "observed", &v
	return receipt, nil
}
