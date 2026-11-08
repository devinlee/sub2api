// Package metonfee 定义托管文本调用的累计费用回报。编解码不授予结算或派发权限。
package metonfee

import (
	"encoding/json"
	"errors"
	"regexp"
)

var (
	label = regexp.MustCompile("^[A-Za-z0-9_.-]{1,120}$")
	id    = regexp.MustCompile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
	money = regexp.MustCompile("^(0|[1-9][0-9]{0,11})[.][0-9]{8}$")
)

// Origin 取自原受理所绑定的来源，不从客户端请求头或当前会话推断。
type Origin struct {
	Environment     string `json:"environment"`
	Source          string `json:"source"`
	SourceMarker    string `json:"source_marker"`
	User            string `json:"user"`
	Account         string `json:"account"`
	Caller          string `json:"caller"`
	OperationID     string `json:"operation_id"`
	SourceRequestID string `json:"source_request_id"`
}

// Item.Amount 始终是该费项当前修订的累计值。最终修订引用被纠正的事件。
type Item struct {
	ChargeItemID    string  `json:"charge_item_id"`
	EventID         string  `json:"event_id"`
	Revision        int32   `json:"revision"`
	State           string  `json:"state"`
	PriceVersion    string  `json:"price_version"`
	Unit            string  `json:"unit"`
	Amount          string  `json:"amount"`
	PreviousEventID *string `json:"previous_event_id"`
}

func validID(value string) bool {
	return id.MatchString(value) && value != "00000000-0000-0000-0000-000000000000"
}

// Encode 只序列化具有完整归属、金额和凭证的回报。没有用量时不制造零费用回报。
func Encode(origin Origin, item Item) ([]byte, error) {
	if !origin.Valid() ||
		!validID(item.ChargeItemID) || !validID(item.EventID) || item.Revision < 1 ||
		!label.MatchString(item.PriceVersion) || !label.MatchString(item.Unit) || !money.MatchString(item.Amount) {
		return nil, errors.New("invalid managed fee report")
	}
	switch item.State {
	case "observed", "final":
		if item.PreviousEventID != nil {
			return nil, errors.New("unexpected previous fee event")
		}
	case "revised":
		if item.Revision < 2 || item.PreviousEventID == nil || !validID(*item.PreviousEventID) || *item.PreviousEventID == item.EventID {
			return nil, errors.New("missing original fee event")
		}
	default:
		return nil, errors.New("unknown fee state")
	}
	return json.Marshal(struct {
		Version int    `json:"version"`
		Origin  Origin `json:"origin"`
		Item    Item   `json:"item"`
	}{1, origin, item})
}
