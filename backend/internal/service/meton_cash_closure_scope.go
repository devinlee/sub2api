package service

import (
	"encoding/json"
	"time"

	"github.com/google/uuid"
)

var closureScopeActions = [...]string{"closure_bind", "closure_scope"}

/** IsCheckoutClosureScope 将确认材料与预查、现金执行分别鉴权。 */
func IsCheckoutClosureScope(action string) bool {
	return action == "closure_bind" || action == "closure_scope"
}

type CashClosureScopeRequest struct {
	Version          int                  `json:"version"`
	Origin           CheckoutOrigin       `json:"origin"`
	Intent           uuid.UUID            `json:"intent"`
	Registration     uuid.UUID            `json:"registration"`
	SourceSystem     string               `json:"sourceSystem"`
	Identity         *CashClosureIdentity `json:"identity"`
	Inspection       uuid.UUID            `json:"inspection"`
	InventoryHash    string               `json:"inventoryHash"`
	ConfirmationHash string               `json:"confirmationHash"`
	ValidUntil       time.Time            `json:"validUntil"`
}

/** 原身份版本是被冻结材料的一部分；查询不以它代替当前独立用途 Key 的权限。 */
func (s *MetonCheckout) parseCashClosureScope(raw []byte, creation, closure uuid.UUID) (*CheckoutRequest, error) {
	var q CashClosureScopeRequest
	if len(raw) > 8192 || decodeGift(raw, &q) != nil {
		return nil, ErrCheckoutDenied
	}
	o, f, now := q.Origin, q.Identity, time.Now()
	if q.Version != 1 || q.Intent != closure || closure == uuid.Nil || creation == uuid.Nil || o.Creation != creation ||
		q.Registration == uuid.Nil || q.Inspection == uuid.Nil || !closureSystem.MatchString(q.SourceSystem) ||
		!refundVersion.MatchString(q.InventoryHash) || !refundVersion.MatchString(q.ConfirmationHash) ||
		o.Environment != s.Source.Environment || o.Source != s.Source.Source || o.Epoch != s.Source.Epoch || o.User == uuid.Nil ||
		o.Account == uuid.Nil || o.Dispatch == uuid.Nil || o.RemoteUser < 1 || o.SourceMarker == uuid.Nil ||
		!q.ValidUntil.After(now) || q.ValidUntil.After(now.Add(30*time.Second)) || f == nil || f.Lifecycle != "active" ||
		f.SecurityVersion < 1 || f.RecoveryVersion < 1 || f.LastStopVersion < 0 || f.LastStopVersion > f.SecurityVersion {
		return nil, ErrCheckoutDenied
	}
	return &CheckoutRequest{Version: 1, Origin: o, Intent: closure, ValidUntil: q.ValidUntil, cashClosureScope: &q}, nil
}

/** 固定回执不表示 Identity 已提交，不能作为新的资金执行授权。查询原回执不要求检查仍未到期。 */
func cashClosureScopeReceipt(receipt *CheckoutReceipt, request *CheckoutRequest, state string) (*CheckoutReceipt, error) {
	q := request.cashClosureScope
	var raw map[string]json.RawMessage
	if q == nil || len(state) > 32768 || decodeGift([]byte(state), &raw) != nil {
		return nil, ErrMetonClosed
	}
	var status string
	var closure, inspection uuid.UUID
	if json.Unmarshal(raw["state"], &status) != nil || json.Unmarshal(raw["closure"], &closure) != nil || closure != q.Intent ||
		json.Unmarshal(raw["inspection"], &inspection) != nil || inspection != q.Inspection {
		return nil, ErrMetonClosed
	}
	r := &CashClosureResult{Version: 1, Origin: q.Origin, Registration: q.Registration, Identity: *q.Identity,
		Reference: closure, SourceSystem: q.SourceSystem, State: status}
	if (status == "expired" || status == "scope_changed") && len(raw) == 3 {
		receipt.ClosureScope = r
		return receipt, nil
	}
	var v struct {
		Format     int       `json:"format"`
		Purpose    string    `json:"purpose"`
		Closure    uuid.UUID `json:"closure"`
		Inspection uuid.UUID `json:"inspection"`
		Origin     struct {
			Environment  string    `json:"environment"`
			Source       string    `json:"source"`
			Epoch        int64     `json:"epoch"`
			User         uuid.UUID `json:"user"`
			Account      uuid.UUID `json:"account"`
			Creation     uuid.UUID `json:"creation"`
			Dispatch     uuid.UUID `json:"dispatch"`
			RemoteUser   int64     `json:"remote_user"`
			SourceMarker uuid.UUID `json:"source_marker"`
			SourceSystem string    `json:"source_system"`
		} `json:"origin"`
		Registration        uuid.UUID           `json:"registration"`
		Identity            CashClosureIdentity `json:"identity"`
		InventoryHash       string              `json:"inventoryHash"`
		ConfirmationHash    string              `json:"confirmationHash"`
		Count               int                 `json:"count"`
		Cut                 json.RawMessage     `json:"cut"`
		InspectionExpiresAt time.Time           `json:"inspectionExpiresAt"`
		State               string              `json:"state"`
		BoundAt             time.Time           `json:"boundAt"`
		ScopeHash           string              `json:"scopeHash"`
		Meaning             string              `json:"meaning"`
	}
	if decodeGift([]byte(state), &v) != nil || len(raw) != 16 || status != "bound" || v.Format != 1 || v.Purpose != "cash_closure_scope" ||
		v.Registration != q.Registration || v.Identity != *q.Identity || v.InventoryHash != q.InventoryHash || v.ConfirmationHash != q.ConfirmationHash ||
		(CheckoutOrigin{v.Origin.Environment, v.Origin.Source, v.Origin.Epoch, v.Origin.User, v.Origin.Account, v.Origin.Creation, v.Origin.Dispatch, v.Origin.RemoteUser, v.Origin.SourceMarker}) != q.Origin ||
		v.Origin.SourceSystem != q.SourceSystem || v.Count < 0 || len(v.Cut) == 0 || !refundVersion.MatchString(v.ScopeHash) ||
		v.BoundAt.Before(time.Unix(0, 0)) || v.BoundAt.After(time.Now().Add(time.Minute)) || !v.InspectionExpiresAt.After(v.BoundAt) ||
		v.Meaning != "scope_only_identity_commit_and_execution_recheck_required" {
		return nil, ErrMetonClosed
	}
	r.View = json.RawMessage(state)
	receipt.ClosureScope = r
	return receipt, nil
}
