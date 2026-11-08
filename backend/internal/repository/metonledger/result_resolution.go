//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
)

// ResultProofKey 固定首次观察和原发送摘要，不能用后来登录的请求替换。
type ResultProofKey struct {
	PriorEvent  string
	ContextHash string
	EvidenceID  string
}

// ResultProof 来自受限来源观察身份。形状有效不表示已取得外部证明或运营批准。
type ResultProof struct {
	EvidenceID  string               `json:"evidence_id"`
	RequestID   string               `json:"request_id"`
	PriorEvent  string               `json:"prior_event"`
	ContextHash string               `json:"context_hash"`
	Epoch       int64                `json:"epoch"`
	Observation metonresult.Snapshot `json:"observation"`
	Observer    string               `json:"observer"`
	RecordedAt  time.Time            `json:"recorded_at"`
}

// ResultResolutionKey 只引用已登记的证据和原运营执行，不接收金额或新用量。
type ResultResolutionKey struct {
	EvidenceID     string `json:"evidence_id"`
	CaseID         string `json:"case_id"`
	AttemptID      string `json:"attempt_id"`
	ApprovalDigest string `json:"approval_digest"`
}

type ResultResolution struct {
	Version int             `json:"version"`
	Origin  metonfee.Origin `json:"origin"`
	ResultResolutionKey
	PriorEvent string          `json:"prior_event"`
	Result     ExecutionResult `json:"result"`
}

func resultDigest(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 32 && hex.EncodeToString(b) == s
}

func validResultProofKey(k ResultProofKey) bool {
	return originalID(k.PriorEvent) && originalID(k.EvidenceID) && resultDigest(k.ContextHash)
}

func validResultResolutionKey(k ResultResolutionKey) bool {
	return originalID(k.EvidenceID) && originalID(k.CaseID) && originalID(k.AttemptID) && resultDigest(k.ApprovalDigest)
}

func knownResultObservation(s metonresult.Snapshot) bool {
	return s.Valid() && s.Execution != "unknown" && s.FeeReady && s.ReadEnd == "eof"
}

/** RecordResultProof 仅给受信供应观察器使用；数据库复验原规格，记录本身没有资金效果。 */
func (l *TextLedger) RecordResultProof(ctx context.Context, o metonfee.Origin, k ResultProofKey, spec metonexecution.Record, s metonresult.Snapshot) (*ResultProof, error) {
	if !l.currentSource() || !o.Valid() || !validResultProofKey(k) || spec.Version != 1 ||
		!knownResultObservation(s) || spec.WireProtocol != s.Protocol {
		return nil, errOriginalFee
	}
	frozen, _ := json.Marshal(spec)
	observed, _ := json.Marshal(s)
	r, err := l.resultProof(ctx, o, k, "record_text_result_proof($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)",
		[]any{k.PriorEvent, k.ContextHash, string(frozen), k.EvidenceID, string(observed)})
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(r.Observation, s) {
		return nil, errOriginalFee
	}
	return r, nil
}

/** FindResultProof 用独立只读连接找回原登记；查无或未知不能变成另一个证据编号。 */
func (l *TextLedger) FindResultProof(ctx context.Context, o metonfee.Origin, k ResultProofKey) (*ResultProof, error) {
	return l.resultProof(ctx, o, k, "find_text_result_proof($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)", []any{k.EvidenceID})
}

func (l *TextLedger) resultProof(ctx context.Context, o metonfee.Origin, k ResultProofKey, query string, args []any) (*ResultProof, error) {
	if !l.currentSource() || !o.Valid() || !validResultProofKey(k) {
		return nil, errOriginalFee
	}
	var raw json.RawMessage
	if err := l.feeCommand(ctx, o, query, args, &raw); err != nil {
		return nil, err
	}
	var r ResultProof
	if metonexecution.DecodeStrict(raw, &r) != nil || !l.currentSource() || r.RequestID != o.SourceRequestID ||
		r.EvidenceID != k.EvidenceID || r.PriorEvent != k.PriorEvent || r.ContextHash != k.ContextHash || r.Epoch <= 0 || r.Epoch > l.epoch ||
		!knownResultObservation(r.Observation) || r.Observer == "" || len(r.Observer) > 63 || r.RecordedAt.IsZero() {
		return nil, errOriginalFee
	}
	return &r, nil
}

/** ApplyResultProof 按原批准执行一次；提交未知交回调用方，方法内不重试、不重造 Attempt。 */
func (l *TextLedger) ApplyResultProof(ctx context.Context, o metonfee.Origin, k ResultResolutionKey) (*ResultResolution, error) {
	return l.resultResolution(ctx, o, k, "apply_text_result_proof($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
		[]any{k.EvidenceID, k.CaseID, k.AttemptID, k.ApprovalDigest})
}

/** FindResultResolution 只读取原结案；当前人员授权仍须由所属运营入口复验。 */
func (l *TextLedger) FindResultResolution(ctx context.Context, o metonfee.Origin, k ResultResolutionKey) (*ResultResolution, error) {
	return l.resultResolution(ctx, o, k, "find_text_resolution($1,$2,$3,$4,$5,$6,$7,$8,$9)", nil)
}

func (l *TextLedger) resultResolution(ctx context.Context, o metonfee.Origin, k ResultResolutionKey, query string, args []any) (*ResultResolution, error) {
	if !l.currentSource() || !o.Valid() || !validResultResolutionKey(k) {
		return nil, errOriginalFee
	}
	var raw json.RawMessage
	if err := l.feeCommand(ctx, o, query, args, &raw); err != nil {
		return nil, err
	}
	var r ResultResolution
	if metonexecution.DecodeStrict(raw, &r) != nil || !l.currentSource() || verifyResultResolution(r, o, k) != nil {
		return nil, errOriginalFee
	}
	return &r, nil
}

func verifyResultResolution(r ResultResolution, o metonfee.Origin, k ResultResolutionKey) error {
	if r.Version != 1 || r.Origin != o || !o.Valid() || !validResultResolutionKey(k) || r.ResultResolutionKey != k ||
		!originalID(r.PriorEvent) || r.PriorEvent == r.Result.EventID || !knownResultObservation(r.Result.Observation) ||
		verifyExecution(r.Result, o) != nil {
		return errOriginalFee
	}
	return nil
}
