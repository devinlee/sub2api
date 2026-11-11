package service

import (
	"github.com/google/uuid"
	"time"
)

/** CashAccountState 只接受 Identity 原注册和已受理注销事实，不能用它代替收银台或模型会话。 */
type CashAccountState struct {
	Lifecycle        string     `json:"lifecycle"`
	SecurityVersion  int64      `json:"securityVersion"`
	RecoveryVersion  int64      `json:"recoveryVersion"`
	LastStopVersion  int64      `json:"lastStopVersion"`
	Sequence         int64      `json:"sequence"`
	PreparingClosure *uuid.UUID `json:"preparingClosure,omitempty"`
}

func (s *MetonCheckout) parseCashAccount(raw []byte, creation, registration uuid.UUID) (*CheckoutRequest, error) {
	var q struct {
		Version     int               `json:"version"`
		Origin      CheckoutOrigin    `json:"origin"`
		Intent      uuid.UUID         `json:"intent"`
		AccountFact *CashAccountState `json:"accountFact"`
		ValidUntil  time.Time         `json:"validUntil"`
	}
	if len(raw) > 8192 || decodeGift(raw, &q) != nil {
		return nil, ErrCheckoutDenied
	}
	o, f, now := q.Origin, q.AccountFact, time.Now()
	if q.Version != 1 || q.Intent != registration || registration == uuid.Nil || creation == uuid.Nil || o.Creation != creation ||
		o.Environment != s.Source.Environment || o.Source != s.Source.Source || o.Epoch != s.Source.Epoch || o.User == uuid.Nil ||
		o.Account == uuid.Nil || o.Dispatch == uuid.Nil || o.RemoteUser < 1 || o.SourceMarker == uuid.Nil ||
		!q.ValidUntil.After(now) || q.ValidUntil.After(now.Add(30*time.Second)) ||
		f == nil || f.SecurityVersion < 1 || f.RecoveryVersion < 1 || f.LastStopVersion < 0 || f.LastStopVersion > f.SecurityVersion ||
		f.Sequence < 1 || f.PreparingClosure != nil && (*f.PreparingClosure == uuid.Nil || f.Lifecycle != "active") {
		return nil, ErrCheckoutDenied
	}
	switch f.Lifecycle {
	case "active", "security_recovery":
	case "closing", "closed", "disabled":
		if f.LastStopVersion != f.SecurityVersion {
			return nil, ErrCheckoutDenied
		}
	default:
		return nil, ErrCheckoutDenied
	}
	return &CheckoutRequest{Version: 1, Origin: o, Intent: registration, ValidUntil: q.ValidUntil, accountFact: f}, nil
}
