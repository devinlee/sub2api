package service

import (
	"regexp"
	"strconv"
	"time"

	"github.com/google/uuid"
)

var checkoutOrderActions = []string{"quote", "confirm", "order"}
var purchaseName = regexp.MustCompile(`^[a-z][a-z0-9_.-]*$`)

type CheckoutSelection struct {
	Product  string     `json:"product"`
	Channel  string     `json:"channel"`
	Currency string     `json:"currency"`
	PriceFen int64      `json:"priceFen"`
	Quote    *uuid.UUID `json:"quote,omitempty"`
}

func (s *CheckoutSelection) valid(action string) bool {
	return s != nil && len(s.Product) <= 80 && purchaseName.MatchString(s.Product) &&
		len(s.Channel) <= 48 && purchaseName.MatchString(s.Channel) && s.Currency == "CNY" && s.PriceFen >= 1000 && s.PriceFen <= 2147483647 &&
		(action == "quote" && s.Quote == nil || (action == "confirm" || action == "present") && s.Quote != nil && *s.Quote != uuid.Nil)
}

/** CheckoutOrder 只含原订单快照与现金、额度状态。购买证明和支付码不能从普通账单查询返回。 */
type CheckoutOrder struct {
	Intent           uuid.UUID           `json:"intent"`
	Quote            uuid.UUID           `json:"quote"`
	Product          string              `json:"product"`
	Channel          string              `json:"channel"`
	Environment      string              `json:"environment"`
	Merchant         string              `json:"merchant"`
	App              string              `json:"app"`
	PriceVersion     string              `json:"priceVersion"`
	Unit             string              `json:"unit"`
	PriceFen         int64               `json:"priceFen"`
	Currency         string              `json:"currency"`
	CreditUnits      string              `json:"creditUnits"`
	QuoteExpiresAt   time.Time           `json:"quoteExpiresAt"`
	Order            *int64              `json:"order"`
	OutTradeNo       *string             `json:"outTradeNo"`
	OrderExpiresAt   *time.Time          `json:"orderExpiresAt"`
	Attempt          string              `json:"attempt"`
	PaymentConfirmed bool                `json:"paymentConfirmed"`
	CreditPosted     bool                `json:"creditPosted"`
	CloseState       string              `json:"closeState,omitempty"`
	CloseVersion     int64               `json:"closeVersion,omitempty"`
	// 来源查询显式返回 null；保留该键才能通过严格键形复验，避免把正常报价判为未知。
	CashReview       *CheckoutCashReview `json:"cashReview"`
}

/** CheckoutCashReview 只显示本单的已核实现金，金额沿用分的整数字符串。 */
type CheckoutCashReview struct {
	Reason      string `json:"reason"`
	ReceivedFen string `json:"receivedFen"`
	UnpostedFen string `json:"unpostedFen"`
}

var cashFen = regexp.MustCompile(`^(0|[1-9][0-9]{0,37})$`)

func (r *CheckoutCashReview) valid() bool {
	if r == nil {
		return true
	}
	return (r.Reason == "refund_notice" || r.Reason == "payment_conflict" || r.Reason == "unposted_cash" && r.UnpostedFen != "0") &&
		cashFen.MatchString(r.ReceivedFen) && cashFen.MatchString(r.UnpostedFen) &&
		(len(r.UnpostedFen) < len(r.ReceivedFen) || len(r.UnpostedFen) == len(r.ReceivedFen) && r.UnpostedFen <= r.ReceivedFen)
}

/** orderReceipt 的写回执只给原号。展示/恢复通过独立查询读取来源中的报价与原单。 */
func orderReceipt(receipt *CheckoutReceipt, action, value string) (*CheckoutReceipt, error) {
	switch action {
	case "quote":
		id, err := uuid.Parse(value)
		if err != nil || id == uuid.Nil || id.String() != value {
			return nil, ErrMetonClosed
		}
		receipt.State, receipt.Reference = "quoted", value
	case "confirm":
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil || n <= 0 || strconv.FormatInt(n, 10) != value {
			return nil, ErrMetonClosed
		}
		receipt.State, receipt.Reference = "prepared", value
	case "order":
		var order struct {
			CheckoutOrder
			CashierCode  string    `json:"cashierCode,omitempty"`
			CashierUntil time.Time `json:"cashierUntil,omitempty"`
		}
		if decodeGift([]byte(value), &order) != nil || order.Intent != receipt.Intent || order.Quote == uuid.Nil ||
			order.QuoteExpiresAt.IsZero() || order.PriceFen < 1000 || order.Currency != "CNY" || !order.CashReview.valid() ||
			order.CashReview != nil && (order.Order == nil || !order.PaymentConfirmed && order.CashReview.ReceivedFen != "0") {
			return nil, ErrMetonClosed
		}
		if order.CashierCode != "" {
			if receipt.Browser == nil || order.Attempt != "presented" || order.PaymentConfirmed || order.CashReview != nil || order.CashierUntil.IsZero() ||
				order.CloseState != "" && order.CloseState != "open" {
				return nil, ErrMetonClosed
			}
			code, err := checkoutMatrix(order.CashierCode)
			if err != nil {
				return nil, err
			}
			code.ExpiresAt = order.CashierUntil
			receipt.Code = code
		}
		receipt.State, receipt.Order = "observed", &order.CheckoutOrder
	default:
		return nil, ErrCheckoutDenied
	}
	return receipt, nil
}
