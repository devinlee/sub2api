package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/google/uuid"
)

const CheckoutRoute = "/meton/managed-accounts/:operation/checkout/:intent/"

/** CheckoutActions 供托管外层入口和原生路由共同登记。每个处理器继续单独复验对应用途。 */
func CheckoutActions() []string {
	actions := append([]string{"issue", "redeem", "status", "quote", "confirm", "order", "present", "cancel", "lifecycle"}, refundActions[:]...)
	return append(append(append(append(append(actions, "refund_cancel"), disputeActions[:]...), closureActions[:]...), closureScopeActions[:]...), closureRefundActions[:]...)
}

var ErrCheckoutDenied = errors.New("checkout denied")
var ErrCheckoutConflict = errors.New("checkout intent conflict")

type CheckoutOrigin struct {
	Environment  string    `json:"environment"`
	Source       string    `json:"source"`
	Epoch        int64     `json:"epoch"`
	User         uuid.UUID `json:"user"`
	Account      uuid.UUID `json:"account"`
	Creation     uuid.UUID `json:"creation"`
	Dispatch     uuid.UUID `json:"dispatch"`
	RemoteUser   int64     `json:"remoteUser"`
	SourceMarker uuid.UUID `json:"sourceMarker"`
}
type CheckoutSubject struct {
	User            uuid.UUID `json:"user"`
	Session         uuid.UUID `json:"session"`
	Family          uuid.UUID `json:"family"`
	SecurityVersion int64     `json:"securityVersion"`
	RecoveryVersion int64     `json:"recoveryVersion"`
}
type CheckoutRequest struct {
	Version            int                `json:"version"`
	Origin             CheckoutOrigin     `json:"origin"`
	Desktop            CheckoutSubject    `json:"desktop"`
	Browser            *CheckoutSubject   `json:"browser,omitempty"`
	Intent             uuid.UUID          `json:"intent"`
	ValidUntil         time.Time          `json:"validUntil"`
	ReturnTarget       string             `json:"returnTarget,omitempty"`
	ChallengeHash      []byte             `json:"challengeHash,omitempty"`
	Challenge          []byte             `json:"challenge,omitempty"`
	WebProof           []byte             `json:"webProof,omitempty"`
	Selection          *CheckoutSelection `json:"selection,omitempty"`
	WantCode           bool               `json:"wantCode,omitempty"`
	CloseVersion       int64              `json:"closeVersion,omitempty"`
	accountFact        *CashAccountState
	refundSelection    *RefundSelection
	refundConfirmation *RefundConfirmation
	memberDispute      *MemberDisputeRequest
	refundCancellation *RefundCancellation
	cashClosure        *CashClosureRequest
	cashClosureRefund  *CashClosureRefundRequest
	cashClosureScope   *CashClosureScopeRequest
}
type CheckoutReceipt struct {
	Version           int                      `json:"version"`
	Intent            uuid.UUID                `json:"intent"`
	Origin            CheckoutOrigin           `json:"origin"`
	Desktop           CheckoutSubject          `json:"desktop"`
	Browser           *CheckoutSubject         `json:"browser"`
	Purpose           string                   `json:"purpose"`
	ReturnTarget      string                   `json:"returnTarget"`
	State             string                   `json:"state"`
	Reference         string                   `json:"reference,omitempty"`
	Order             *CheckoutOrder           `json:"order,omitempty"`
	Code              *CheckoutCode            `json:"code,omitempty"`
	ChannelOrderFound bool                     `json:"channelOrderFound,omitempty"`
	AccountFact       *CashAccountState        `json:"-"`
	RefundQuote       *CheckoutRefundQuote     `json:"refundQuote,omitempty"`
	RefundDecision    *CheckoutRefundDecision  `json:"refundDecision,omitempty"`
	Dispute           *MemberDisputeResult     `json:"dispute,omitempty"`
	ClosureCheck      *CashClosureResult       `json:"-"`
	ClosureScope      *CashClosureResult       `json:"-"`
	ClosureRefund     *CashClosureRefundResult `json:"-"`
}
type CheckoutAccess struct {
	Key      string
	Creator  int64
	Revision time.Time
	UntilMS  int64
	Witness  string
}
type CheckoutStore interface {
	Checkout(context.Context, string, []byte, CheckoutAccess) (string, error)
}
type MetonCheckout struct {
	Source   MetonManagedSource
	Keys     map[string]string
	Store    CheckoutStore
	Route    *CheckoutPaymentRoute
	Payments CheckoutPaymentResolver
}

/** CheckoutKeyIDs 限本次来源代次。签发、兑换与查询不能共用某个既有控制身份。 */
func CheckoutKeyIDs() (map[string]string, bool) {
	if os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" {
		return nil, false
	}
	counts := map[string]int{}
	for _, entry := range os.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if ok && strings.HasPrefix(name, "METON_MANAGED_") && strings.HasSuffix(name, "_KEY_ID") {
			counts[value]++
		}
	}
	ids := map[string]string{}
	actions := []string{"issue", "redeem", "status"}
	for _, action := range checkoutOrderActions {
		if os.Getenv("METON_MANAGED_CHECKOUT_"+strings.ToUpper(action)+"_KEY_ID") != "" {
			actions = append(actions, checkoutOrderActions...)
			break
		}
	}
	if os.Getenv("METON_MANAGED_CHECKOUT_PRESENT_KEY_ID") != "" {
		if os.Getenv("METON_MANAGED_CHECKOUT_ORDER_KEY_ID") == "" {
			return nil, false
		}
		actions = append(actions, "present")
	}
	for _, action := range []string{"cancel", "lifecycle"} {
		if os.Getenv("METON_MANAGED_CHECKOUT_"+strings.ToUpper(action)+"_KEY_ID") != "" {
			if os.Getenv("METON_MANAGED_CHECKOUT_ORDER_KEY_ID") == "" {
				return nil, false
			}
			actions = append(actions, action)
		}
	}
	for _, action := range refundActions {
		if os.Getenv("METON_MANAGED_CHECKOUT_"+strings.ToUpper(action)+"_KEY_ID") != "" {
			if os.Getenv("METON_MANAGED_CHECKOUT_LIFECYCLE_KEY_ID") == "" {
				return nil, false
			}
			actions = append(actions, refundActions[:]...)
			break
		}
	}
	if os.Getenv("METON_MANAGED_CHECKOUT_REFUND_CANCEL_KEY_ID") != "" {
		if os.Getenv("METON_MANAGED_CHECKOUT_REFUND_STATUS_KEY_ID") == "" {
			return nil, false
		}
		actions = append(actions, "refund_cancel")
	}
	for _, action := range disputeActions {
		if os.Getenv("METON_MANAGED_CHECKOUT_"+strings.ToUpper(action)+"_KEY_ID") != "" {
			if os.Getenv("METON_MANAGED_CHECKOUT_LIFECYCLE_KEY_ID") == "" {
				return nil, false
			}
			actions = append(actions, disputeActions[:]...)
			break
		}
	}
	for _, action := range closureActions {
		if os.Getenv("METON_MANAGED_CHECKOUT_"+strings.ToUpper(action)+"_KEY_ID") != "" {
			if os.Getenv("METON_MANAGED_CHECKOUT_LIFECYCLE_KEY_ID") == "" {
				return nil, false
			}
			actions = append(actions, closureActions[:]...)
			break
		}
	}
	for _, action := range closureScopeActions {
		if os.Getenv("METON_MANAGED_CHECKOUT_"+strings.ToUpper(action)+"_KEY_ID") != "" {
			if os.Getenv("METON_MANAGED_CHECKOUT_CLOSURE_OPEN_KEY_ID") == "" {
				return nil, false
			}
			actions = append(actions, closureScopeActions[:]...)
			break
		}
	}
	for _, action := range closureRefundActions {
		if os.Getenv("METON_MANAGED_CHECKOUT_"+strings.ToUpper(action)+"_KEY_ID") != "" {
			if os.Getenv("METON_MANAGED_CHECKOUT_CLOSURE_BIND_KEY_ID") == "" {
				return nil, false
			}
			actions = append(actions, closureRefundActions[:]...)
			break
		}
	}
	for _, action := range actions {
		id := os.Getenv("METON_MANAGED_CHECKOUT_" + strings.ToUpper(action) + "_KEY_ID")
		if !metonKeyID.MatchString(id) || counts[id] != 1 {
			return nil, false
		}
		ids[action] = id
	}
	return ids, true
}

/** Allows 既检查实际认证主体，也限制该身份只有路由所需的一项权限。 */
func (s *MetonCheckout) Allows(action string, p *adminaccess.Principal) bool {
	source, ok := MetonSource()
	ids, enabled := CheckoutKeyIDs()
	return s != nil && s.Store != nil && p != nil && ok && enabled && source == s.Source &&
		p.KeyID != "" && ids[action] == p.KeyID && s.Keys[action] == p.KeyID && p.CreatorID > 0 && !p.KeyRevision.IsZero() &&
		len(p.Policy.Rules) == 0 && len(p.Policy.GlobalPermissions) == 1 && p.Policy.GlobalPermissions[0] == "meton.checkout."+action
}

func (s CheckoutSubject) valid(user uuid.UUID) bool {
	return s.User == user && user != uuid.Nil && s.Session != uuid.Nil && s.Family != uuid.Nil && s.SecurityVersion > 0 && s.RecoveryVersion > 0
}

func (q *CheckoutRequest) validSession(source MetonManagedSource, creation, intent uuid.UUID) bool {
	o := q.Origin
	now := time.Now()
	return q.Version == 1 && q.Intent == intent && intent != uuid.Nil && o.Creation == creation && creation != uuid.Nil &&
		o.Environment == source.Environment && o.Source == source.Source && o.Epoch == source.Epoch && o.Account != uuid.Nil &&
		o.Dispatch != uuid.Nil && o.SourceMarker != uuid.Nil && o.RemoteUser > 0 && q.Desktop.valid(o.User) &&
		q.ValidUntil.After(now) && !q.ValidUntil.After(now.Add(30*time.Second))
}

/** 兑换用的原材料和签发摘要严格分开；字符串、追加字段及重复键由原严格解析器检查。 */
func (s *MetonCheckout) parse(raw []byte, action string, creation, intent uuid.UUID) (*CheckoutRequest, error) {
	if IsCheckoutClosureRefund(action) {
		return s.parseCashClosureRefund(raw, action, creation, intent)
	}
	if IsCheckoutClosureScope(action) {
		return s.parseCashClosureScope(raw, creation, intent)
	}
	if IsCheckoutClosure(action) {
		return s.parseCashClosure(raw, action, creation, intent)
	}
	if IsCheckoutDispute(action) {
		return s.parseMemberDispute(raw, action, creation, intent)
	}
	if IsCheckoutRefund(action) {
		return s.parseMemberRefund(raw, action, creation, intent)
	}
	if action == "lifecycle" {
		return s.parseCashAccount(raw, creation, intent)
	}
	var q CheckoutRequest
	if len(raw) > 8192 || decodeGift(raw, &q) != nil {
		return nil, ErrCheckoutDenied
	}
	o := q.Origin
	if !q.validSession(s.Source, creation, intent) {
		return nil, ErrCheckoutDenied
	}
	if action != "quote" && action != "confirm" && action != "present" && q.Selection != nil || q.WantCode && (action != "order" || q.Browser == nil) ||
		action != "cancel" && q.CloseVersion != 0 {
		return nil, ErrCheckoutDenied
	}
	switch action {
	case "issue":
		if q.ReturnTarget != "account.credits" || len(q.ChallengeHash) != 32 || q.Browser != nil || q.Challenge != nil || q.WebProof != nil {
			return nil, ErrCheckoutDenied
		}
	case "redeem":
		b := q.Browser
		if b == nil || !b.valid(o.User) || b.SecurityVersion != q.Desktop.SecurityVersion || b.RecoveryVersion != q.Desktop.RecoveryVersion ||
			len(q.Challenge) != 32 || len(q.WebProof) != 32 || bytes.Equal(q.Challenge, q.WebProof) || q.ReturnTarget != "" || q.ChallengeHash != nil {
			return nil, ErrCheckoutDenied
		}
	case "quote", "confirm", "present":
		b := q.Browser
		if b == nil || !b.valid(o.User) || b.SecurityVersion != q.Desktop.SecurityVersion || b.RecoveryVersion != q.Desktop.RecoveryVersion ||
			len(q.WebProof) != 32 || q.ReturnTarget != "" || q.Challenge != nil || q.ChallengeHash != nil || !q.Selection.valid(action) {
			return nil, ErrCheckoutDenied
		}
	case "cancel":
		b := q.Browser
		if b == nil || !b.valid(o.User) || b.SecurityVersion != q.Desktop.SecurityVersion || b.RecoveryVersion != q.Desktop.RecoveryVersion ||
			len(q.WebProof) != 32 || q.CloseVersion <= 0 || q.ReturnTarget != "" || q.Challenge != nil || q.ChallengeHash != nil {
			return nil, ErrCheckoutDenied
		}
	case "order":
		b := q.Browser
		if q.ReturnTarget != "" || q.Challenge != nil || q.ChallengeHash != nil || b == nil && q.WebProof != nil ||
			b != nil && (!b.valid(o.User) || b.SecurityVersion != q.Desktop.SecurityVersion || b.RecoveryVersion != q.Desktop.RecoveryVersion || len(q.WebProof) != 32) {
			return nil, ErrCheckoutDenied
		}
	case "status":
		if q.Browser != nil || q.ReturnTarget != "" || q.Challenge != nil || q.ChallengeHash != nil || q.WebProof != nil {
			return nil, ErrCheckoutDenied
		}
	default:
		return nil, ErrCheckoutDenied
	}
	return &q, nil
}

/** Run 绑定原始 HTTP 正文摘要、实际管理员和短截止；签发与兑换各最多调用一次数据库。 */
func (s *MetonCheckout) Run(ctx context.Context, action string, creation, intent uuid.UUID, raw []byte,
	p *adminaccess.Principal, key string) (*CheckoutReceipt, error) {
	if !s.Allows(action, p) {
		return nil, ErrCheckoutDenied
	}
	q, err := s.parse(raw, action, creation, intent)
	if err != nil {
		return nil, err
	}
	var sender CheckoutPaymentSender
	if action == "present" {
		if s.Route == nil || s.Payments == nil || !s.Route.Valid() {
			return nil, ErrCheckoutDenied
		}
		sender, err = s.Payments.CheckoutPayment(ctx, *s.Route)
		if err != nil || sender == nil {
			return nil, ErrMetonClosed
		}
		raw, err = checkoutDispatchWire(q, s.Route)
		if err != nil {
			return nil, ErrMetonClosed
		}
	}
	prefix := "adm_sc_" + p.KeyID + "_"
	if !strings.HasPrefix(key, prefix) || len(key) != len(prefix)+64 || strings.Trim(key[len(prefix):], "0123456789abcdef") != "" {
		return nil, ErrCheckoutDenied
	}
	until := time.Now().Add(4 * time.Second)
	if q.ValidUntil.Before(until) {
		until = q.ValidUntil
	}
	if e := p.KeyExpiresAt; e != nil && e.Before(until) {
		until = *e
	}
	if until.UnixMilli() <= time.Now().UnixMilli() {
		return nil, ErrCheckoutDenied
	}
	verifier := sha256.Sum256([]byte(key))
	body := sha256.Sum256(raw)
	fields := []string{"meton.checkout.http.v1", action, p.KeyID, strconv.FormatInt(p.CreatorID, 10),
		strconv.FormatInt(until.UnixMilli(), 10), hex.EncodeToString(body[:]), hex.EncodeToString(verifier[:])}
	witness := sha256.Sum256([]byte(strings.Join(fields, "|")))
	access := CheckoutAccess{p.KeyID, p.CreatorID, p.KeyRevision, until.UnixMilli(), hex.EncodeToString(witness[:])}
	state, err := s.Store.Checkout(ctx, action, raw, access)
	if err != nil {
		return nil, err
	}
	if action == "present" && state != "lookup" {
		if !s.Allows(action, p) || !time.Now().Before(until) {
			return nil, ErrMetonClosed
		}
		if err = s.present(ctx, q, state, sender); err != nil {
			return nil, err
		}
		state = "lookup"
	}
	if !s.Allows(action, p) || !time.Now().Before(until) {
		return nil, ErrMetonClosed
	}
	// 只读查询查无可见原号。写入回应缺失不能解释为未执行。
	if CheckoutReadAction(action) && state == "" {
		return nil, nil
	}
	receipt := &CheckoutReceipt{Version: 1, Intent: q.Intent, Origin: q.Origin, Desktop: q.Desktop, Browser: q.Browser,
		Purpose: "purchase", ReturnTarget: "account.credits", State: state}
	if IsCheckoutClosureRefund(action) {
		return cashClosureRefundReceipt(receipt, q, action, state)
	}
	if IsCheckoutClosureScope(action) {
		return cashClosureScopeReceipt(receipt, q, state)
	}
	if IsCheckoutClosure(action) {
		return cashClosureReceipt(receipt, q, action, state)
	}
	if IsCheckoutDispute(action) {
		return memberDisputeReceipt(receipt, q, action, state)
	}
	if IsCheckoutRefund(action) {
		return memberRefundReceipt(receipt, q, action, state)
	}
	if action == "lifecycle" {
		if state != "observed" && state != "superseded" {
			return nil, ErrMetonClosed
		}
		receipt.AccountFact = q.accountFact
		return receipt, nil
	}
	if action == "present" && state == "lookup" {
		return receipt, nil
	}
	if action == "cancel" {
		switch state {
		case "awaiting_query", "possibly_sent", "unknown", "closed_local", "closed_channel", "paid_review", "review", "paid":
			receipt.State = "lookup"
			return receipt, nil
		default:
			return nil, ErrMetonClosed
		}
	}
	if action == "quote" || action == "confirm" || action == "order" {
		result, err := orderReceipt(receipt, action, state)
		if err != nil || action != "order" || !q.WantCode {
			return result, err
		}
		bounded, cancel := context.WithDeadline(ctx, until)
		defer cancel()
		if s.findCheckoutOrder(bounded, q, result.Order) {
			// 渠道查单允许耗时。交回结果前再从来源复核原收银台、撤销和最新状态，不能交出过期授权下的信息。
			fresh, e := s.Store.Checkout(bounded, action, raw, access)
			if e != nil || fresh == "" {
				return nil, ErrMetonClosed
			}
			result.Code = nil
			result, e = orderReceipt(result, action, fresh)
			if e != nil {
				return nil, e
			}
			result.ChannelOrderFound = result.Order != nil && result.Order.Attempt == "possibly_sent"
		}
		if bounded.Err() != nil {
			return nil, ErrMetonClosed
		}
		return result, nil
	}
	if state != "redeemed" && state != "expired" && !(state == "issued" && action != "redeem") && !(state == "revoked" && action == "status") {
		return nil, ErrMetonClosed
	}
	return receipt, nil
}
