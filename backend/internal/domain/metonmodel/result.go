package metonmodel

import (
	"bytes"
	"encoding/json"
	"io"
	"math/big"
	"reflect"
	"unicode/utf8"

	"github.com/google/uuid"
)

// Result 将执行观察与原来源费用分别投影；Result 为 nil 不证明没有执行。
type Result struct {
	Version   int         `json:"version"`
	Admission Admission   `json:"admission"`
	Result    *Completion `json:"result"`
}
type Completion struct {
	ObservationID string       `json:"observation_id"`
	Execution     string       `json:"execution"`
	Usage         *ResultUsage `json:"usage"`
	Fee           *ResultFee   `json:"fee"`
}
type ResultUsage struct {
	Input  int64  `json:"input"`
	Output int64  `json:"output"`
	Cached *int64 `json:"cached"`
}
type ResultFee struct {
	Reference Fee    `json:"reference"`
	Funded    string `json:"funded"`
	Uncovered string `json:"uncovered"`
}

/** ReadResult 只确认原请求的有限事实；原费用缺失、半量计量和原请求未观察到终局分别保留。 */
func ReadResult(raw []byte) (*Result, error) {
	var r Result
	if decodeResult(raw, &r) != nil || r.Version != 1 {
		return nil, ErrReference
	}
	admission, _ := json.Marshal(r.Admission)
	if _, err := ReadAdmission(admission); err != nil {
		return nil, ErrReference
	}
	if r.Result == nil {
		return &r, nil
	}
	c := r.Result
	id, err := uuid.Parse(c.ObservationID)
	if err != nil || id == uuid.Nil || id.String() != c.ObservationID || (c.Execution != "unknown" && c.Execution != "completed" && c.Execution != "failed") {
		return nil, ErrReference
	}
	u := c.Usage
	if u != nil && (u.Input < 0 || u.Input > 100000000 || u.Output < 0 || u.Output > 100000000 || u.Cached != nil && (*u.Cached < 0 || *u.Cached > u.Input)) {
		return nil, ErrReference
	}
	if f := c.Fee; f != nil {
		encoded, _ := json.Marshal(f.Reference)
		if _, err = ReadFee(encoded); err != nil || c.Execution == "unknown" || u == nil || u.Cached == nil || f.Reference.Origin != r.Admission.Origin ||
			f.Reference.Item.ChargeItemID != r.Admission.Origin.SourceRequestID || f.Reference.Item.EventID != c.ObservationID ||
			f.Reference.Item.Revision != 1 || f.Reference.Item.State != "final" || f.Reference.Item.PreviousEventID != nil ||
			f.Reference.Item.PriceVersion != r.Admission.Pricing.Version || f.Reference.Item.Unit != r.Admission.Pricing.Unit ||
			!amount.MatchString(f.Funded) || !amount.MatchString(f.Uncovered) {
			return nil, ErrReference
		}
		a, _ := new(big.Rat).SetString(f.Funded)
		b, _ := new(big.Rat).SetString(f.Uncovered)
		total, _ := new(big.Rat).SetString(f.Reference.Item.Amount)
		if a == nil || b == nil || total == nil || new(big.Rat).Add(a, b).Cmp(total) != 0 {
			return nil, ErrReference
		}
	}
	return &r, nil
}

/** 限制深度、重复键和字段形状；缺少显式 null 也不能靠 Go 零值伪造完整回执。 */
func decodeResult(raw []byte, out any) error {
	if len(raw) == 0 || len(raw) > 8192 || !utf8.Valid(raw) {
		return ErrReference
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	if resultTokens(d, 0) != nil {
		return ErrReference
	}
	if _, err := d.Token(); err != io.EOF {
		return ErrReference
	}
	d = json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(out) != nil {
		return ErrReference
	}
	canonical, err := json.Marshal(out)
	if err != nil {
		return ErrReference
	}
	var a, b any
	if json.Unmarshal(raw, &a) != nil || json.Unmarshal(canonical, &b) != nil || !reflect.DeepEqual(a, b) {
		return ErrReference
	}
	return nil
}

func resultTokens(d *json.Decoder, depth int) error {
	if depth > 8 {
		return ErrReference
	}
	token, err := d.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for d.More() {
			key, err := d.Token()
			name, ok := key.(string)
			if err != nil || !ok || seen[name] {
				return ErrReference
			}
			seen[name] = true
			if resultTokens(d, depth+1) != nil {
				return ErrReference
			}
		}
	case '[':
		for d.More() {
			if resultTokens(d, depth+1) != nil {
				return ErrReference
			}
		}
	default:
		return ErrReference
	}
	closing, err := d.Token()
	if err != nil || delim == '{' && closing != json.Delim('}') || delim == '[' && closing != json.Delim(']') {
		return ErrReference
	}
	return nil
}
