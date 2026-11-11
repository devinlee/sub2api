package service

import (
	"encoding/json"
	"regexp"
	"time"

	"github.com/google/uuid"
)

var closureActions = [...]string{"closure_open", "closure_page"}
var closureSystem = regexp.MustCompile(`^[1-9][0-9]{0,19}$`)

/** IsCheckoutClosure 区分检查材料与现金指令，后续确认不能凭本接口启动退款。 */
func IsCheckoutClosure(action string) bool {
	return action == "closure_open" || action == "closure_page"
}

type CashClosureIdentity struct {
	Lifecycle       string `json:"lifecycle"`
	SecurityVersion int64  `json:"securityVersion"`
	RecoveryVersion int64  `json:"recoveryVersion"`
	LastStopVersion int64  `json:"lastStopVersion"`
}
type CashClosurePage struct {
	After int `json:"after"`
	Size  int `json:"size"`
}
type CashClosureRequest struct {
	Version       int                  `json:"version"`
	Origin        CheckoutOrigin       `json:"origin"`
	Intent        uuid.UUID            `json:"intent"`
	Registration  uuid.UUID            `json:"registration"`
	SourceSystem  string               `json:"sourceSystem"`
	Identity      *CashClosureIdentity `json:"identity"`
	ValidUntil    time.Time            `json:"validUntil"`
	SnapshotUntil *time.Time           `json:"snapshotUntil,omitempty"`
	Page          *CashClosurePage     `json:"page,omitempty"`
}
type CashClosureResult struct {
	Version      int                 `json:"version"`
	Origin       CheckoutOrigin      `json:"origin"`
	Registration uuid.UUID           `json:"registration"`
	Identity     CashClosureIdentity `json:"identity"`
	Reference    uuid.UUID           `json:"reference"`
	SourceSystem string              `json:"sourceSystem"`
	State        string              `json:"state"`
	View         json.RawMessage     `json:"view"`
}

/** parseCashClosure 只接受短期业务身份事实，不收桌面提供的账号覆盖或浏览器交接秘密。 */
func (s *MetonCheckout) parseCashClosure(raw []byte, action string, creation, snapshot uuid.UUID) (*CheckoutRequest, error) {
	var q CashClosureRequest
	if len(raw) > 8192 || decodeGift(raw, &q) != nil {
		return nil, ErrCheckoutDenied
	}
	o, f, now := q.Origin, q.Identity, time.Now()
	if q.Version != 1 || q.Intent != snapshot || snapshot == uuid.Nil || creation == uuid.Nil || o.Creation != creation ||
		q.Registration == uuid.Nil || !closureSystem.MatchString(q.SourceSystem) ||
		o.Environment != s.Source.Environment || o.Source != s.Source.Source || o.Epoch != s.Source.Epoch || o.User == uuid.Nil ||
		o.Account == uuid.Nil || o.Dispatch == uuid.Nil || o.RemoteUser < 1 || o.SourceMarker == uuid.Nil ||
		!q.ValidUntil.After(now) || q.ValidUntil.After(now.Add(30*time.Second)) || f == nil || f.Lifecycle != "active" ||
		f.SecurityVersion < 1 || f.RecoveryVersion < 1 || f.LastStopVersion < 0 || f.LastStopVersion > f.SecurityVersion {
		return nil, ErrCheckoutDenied
	}
	if action == "closure_open" {
		if q.Page != nil || q.SnapshotUntil == nil || !q.SnapshotUntil.After(now) || q.SnapshotUntil.After(now.Add(5*time.Minute)) {
			return nil, ErrCheckoutDenied
		}
	} else if q.SnapshotUntil != nil || q.Page == nil || q.Page.After < 0 || q.Page.Size < 1 || q.Page.Size > 100 {
		return nil, ErrCheckoutDenied
	}
	return &CheckoutRequest{Version: 1, Origin: o, Intent: snapshot, ValidUntil: q.ValidUntil, cashClosure: &q}, nil
}

/** cashClosureReceipt 先核对原材料归属；完整分页及金额复验仍由 Meton 适配器完成。过期不伪装为空清单。 */
func cashClosureReceipt(receipt *CheckoutReceipt, request *CheckoutRequest, action, state string) (*CheckoutReceipt, error) {
	q := request.cashClosure
	var fields map[string]json.RawMessage
	if q == nil || len(state) > 1048576 || decodeGift([]byte(state), &fields) != nil {
		return nil, ErrMetonClosed
	}
	var status string
	var snapshot uuid.UUID
	if json.Unmarshal(fields["state"], &status) != nil || json.Unmarshal(fields["snapshot"], &snapshot) != nil || snapshot != q.Intent {
		return nil, ErrMetonClosed
	}
	r := &CashClosureResult{Version: 1, Origin: q.Origin, Registration: q.Registration, Identity: *q.Identity,
		Reference: snapshot, SourceSystem: q.SourceSystem, State: status}
	if status == "expired" && len(fields) == 2 {
		receipt.ClosureCheck = r
		return receipt, nil
	}
	var owner struct {
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
	}
	var registration uuid.UUID
	var identity CashClosureIdentity
	var expiry time.Time
	var count int
	var hash, meaning string
	var format int
	if status != "observed" || decodeGift(fields["origin"], &owner) != nil || decodeGift(fields["identity"], &identity) != nil ||
		json.Unmarshal(fields["registration"], &registration) != nil || json.Unmarshal(fields["expiresAt"], &expiry) != nil ||
		json.Unmarshal(fields["count"], &count) != nil || json.Unmarshal(fields["format"], &format) != nil ||
		json.Unmarshal(fields["inventoryHash"], &hash) != nil || json.Unmarshal(fields["meaning"], &meaning) != nil ||
		(CheckoutOrigin{owner.Environment, owner.Source, owner.Epoch, owner.User, owner.Account, owner.Creation, owner.Dispatch, owner.RemoteUser, owner.SourceMarker}) != q.Origin ||
		owner.SourceSystem != q.SourceSystem || registration != q.Registration || identity != *q.Identity || format != 1 || count < 0 ||
		!refundVersion.MatchString(hash) || meaning != "inspection_only_not_settled" || !expiry.After(time.Now()) {
		return nil, ErrMetonClosed
	}
	if action == "closure_page" {
		var after, next int
		var more bool
		var items []json.RawMessage
		if len(fields) != 17 || json.Unmarshal(fields["after"], &after) != nil || json.Unmarshal(fields["next"], &next) != nil ||
			json.Unmarshal(fields["more"], &more) != nil || json.Unmarshal(fields["items"], &items) != nil || items == nil ||
			after != q.Page.After || next != after+len(items) || len(items) > q.Page.Size || next > count || more != (next < count) || more && len(items) == 0 {
			return nil, ErrMetonClosed
		}
	} else if len(fields) != 13 {
		return nil, ErrMetonClosed
	}
	r.View = json.RawMessage(state)
	receipt.ClosureCheck = r
	return receipt, nil
}
