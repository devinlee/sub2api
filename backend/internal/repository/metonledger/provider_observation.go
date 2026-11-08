//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
	"reflect"
)

// ProviderOriginal 只从原账本读取，不接收桌面或运营传入的供应账号和终局。
type ProviderOriginal struct {
	Version     int                   `json:"version"`
	Origin      metonfee.Origin       `json:"origin"`
	PriorEvent  string                `json:"prior_event"`
	ContextHash string                `json:"context_hash"`
	Spec        metonexecution.Record `json:"spec"`
	Binding     metonprovider.Binding `json:"binding"`
	Observation metonresult.Snapshot  `json:"observation"`
}

/** FindProviderOriginal 读取同时核对当前来源、原账号和原受理代次；旧记录不补造供应信息。 */
func (l *TextLedger) FindProviderOriginal(ctx context.Context, o metonfee.Origin) (*ProviderOriginal, error) {
	var raw json.RawMessage
	if err := l.feeCommand(ctx, o, "find_provider_original($1,$2,$3,$4,$5,$6,$7,$8,$9)", nil, &raw); err != nil {
		return nil, err
	}
	var r ProviderOriginal
	if metonexecution.DecodeStrict(raw, &r) != nil || !l.currentSource() || r.Version != 1 || !o.Valid() || r.Origin != o ||
		!originalID(r.PriorEvent) || !resultDigest(r.ContextHash) || r.Spec.Version != 1 || !r.Binding.Valid() ||
		!r.Observation.Valid() || r.Observation.FeeReady || r.Observation.Protocol != r.Spec.WireProtocol {
		return nil, errOriginalFee
	}
	return &r, nil
}

/** ObserveProvider 只查原供应并登记证明。运行批准由调用方 guard 复验，资金执行使用另一身份。 */
func (l *TextLedger) ObserveProvider(ctx context.Context, o metonfee.Origin, evidence string, reader *metonprovider.Reader,
	credentials metonprovider.Credentials, observer *TextLedger, guard func(context.Context) error) (*ResultProof, error) {
	if l == nil || observer == nil || l == observer || reader == nil || guard == nil || !originalID(evidence) || guard(ctx) != nil {
		return nil, errOriginalFee
	}
	original, err := l.FindProviderOriginal(ctx, o)
	if err != nil {
		return nil, err
	}
	key := ResultProofKey{PriorEvent: original.PriorEvent, ContextHash: original.ContextHash, EvidenceID: evidence}
	current := func(ctx context.Context) error {
		if guard(ctx) != nil {
			return errOriginalFee
		}
		now, e := l.FindProviderOriginal(ctx, o)
		if e != nil || !reflect.DeepEqual(now, original) {
			return errOriginalFee
		}
		return nil
	}
	// 原登记曾提交而回复丢失时只读找回，避免重新请求远端形成不必要的观察。
	if saved, e := l.FindResultProof(ctx, o, key); e == nil && current(ctx) == nil {
		// 历史登记只供读取，不能借再次观察沿旧 EvidenceId 取得当前写权。
		if saved.Epoch != l.epoch {
			return nil, errOriginalFee
		}
		return saved, nil
	}
	result, err := reader.Read(ctx, original.Binding, original.Spec, original.Observation.ResponseID, credentials, current)
	if err != nil || current(ctx) != nil {
		return nil, errOriginalFee
	}
	proof, err := observer.RecordResultProof(ctx, o, key, original.Spec, result)
	if err != nil {
		// 只读一次原登记，不重交、更换编号或补写另一份事实。
		proof, err = l.FindResultProof(ctx, o, key)
		if err != nil || !reflect.DeepEqual(proof.Observation, result) {
			return nil, errOriginalFee
		}
	}
	if current(ctx) != nil {
		return nil, errOriginalFee
	}
	return proof, nil
}
