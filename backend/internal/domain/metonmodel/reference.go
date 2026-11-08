// Package metonmodel 定义原受理的不可变只读凭证。它不携带正文、会话秘密、余额或再次派发的许可。
package metonmodel

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

type Request struct {
	Protocol      string `json:"protocol"`
	Model         string `json:"model"`
	DigestVersion int    `json:"digest_version"`
	InputDigest   string `json:"input_digest"`
	InputBound    *int   `json:"input_bound"`
	OutputBound   int    `json:"output_bound"`
}
type Pricing struct {
	Version string `json:"version"`
	Unit    string `json:"unit"`
	Quote   string `json:"quote"`
}
type Admission struct {
	Version       int             `json:"version"`
	Origin        metonfee.Origin `json:"origin"`
	AcceptedEpoch int64           `json:"accepted_epoch"`
	Request       Request         `json:"request"`
	Pricing       Pricing         `json:"pricing"`
}
type Fee struct {
	Version int             `json:"version"`
	Origin  metonfee.Origin `json:"origin"`
	Item    metonfee.Item   `json:"item"`
}

var label = regexp.MustCompile("^[A-Za-z0-9_.-]{1,120}$")
var model = regexp.MustCompile("^[A-Za-z0-9_./:-]{1,160}$")
var digest = regexp.MustCompile("^[0-9a-f]{64}$")
var amount = regexp.MustCompile("^(0|[1-9][0-9]{0,11})[.][0-9]{8}$")
var ErrReference = errors.New("original model reference unconfirmed")

/** ReadAdmission 只接受固定规格；可变执行状态和来源分配不进入这一份身份凭证。 */
func ReadAdmission(raw []byte) (*Admission, error) {
	var a Admission
	if decode(raw, &a) != nil || a.Version != 1 || !a.Origin.Valid() || a.AcceptedEpoch <= 0 ||
		(a.Request.Protocol != "responses" && a.Request.Protocol != "chat_completions") || !model.MatchString(a.Request.Model) ||
		a.Request.DigestVersion != 1 || !digest.MatchString(a.Request.InputDigest) || a.Request.InputBound == nil || *a.Request.InputBound < 0 || a.Request.OutputBound <= 0 ||
		!label.MatchString(a.Pricing.Version) || !label.MatchString(a.Pricing.Unit) || !amount.MatchString(a.Pricing.Quote) || a.Pricing.Quote == "0.00000000" {
		return nil, ErrReference
	}
	return &a, nil
}

/** ReadFee 复用原费用协议，原事件查无时不补造零金额或新的费项。 */
func ReadFee(raw []byte) (*Fee, error) {
	var f Fee
	if decode(raw, &f) != nil || f.Version != 1 {
		return nil, ErrReference
	}
	if _, err := metonfee.Encode(f.Origin, f.Item); err != nil {
		return nil, ErrReference
	}
	return &f, nil
}

func decode(raw []byte, dest any) error {
	if len(raw) == 0 || len(raw) > 4096 {
		return ErrReference
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dest); err != nil {
		return err
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return ErrReference
	}
	return nil
}
