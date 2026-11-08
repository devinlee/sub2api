//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
)

/** ReserveTransport 的主体来自已核验的签名，原生 Key 编号取供应认证；来源标记只由数据库交回。 */
func (l *TextLedger) ReserveTransport(ctx context.Context, verified *metondispatch.Verified, key SessionKey, estimate Estimate) (*Hold, error) {
	if !l.currentTransport(verified, key) {
		return nil, metondispatch.ErrProof
	}
	c := verified.Context()
	if estimate.Protocol != c.Protocol || estimate.Model != c.Model || estimate.Digest != c.InputDigest || estimate.DigestVersion != c.DigestVersion ||
		estimate.InputBound < 0 || estimate.OutputBound < 1 {
		return nil, metondispatch.ErrProof
	}
	raw, err := json.Marshal(c)
	if err != nil {
		return nil, err
	}
	conn, err := l.conn(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	// 协议入口共用同一账户限制，不因选择另一条预占适配而跳过保护。
	if err = requireAccountLimit(ctx, conn); err != nil {
		return nil, err
	}
	h, err := scanHold(conn.QueryRowContext(ctx, holdColumns+"reserve_transport_text($1,$2,$3,$4,$5,$6,$7,$8,$9)",
		l.environment, l.source, l.epoch, string(raw), verified.Hash(), verified.Service(), key.ID, estimate.InputBound, estimate.OutputBound))
	if err != nil {
		return nil, err
	}
	if !l.matchesTransport(h, verified) || h.Estimate != estimate {
		return nil, errors.New("different original transport receipt")
	}
	// 事务可能已经完成，但回应到达过晚不能被解释为可以领取；保留原记录以供只读核对。
	if !l.currentTransport(verified, key) {
		return nil, metondispatch.ErrProof
	}
	return h, nil
}

/** ClaimTransport 只返回首次确定提交，绝不以 Find 结果或已经领取的状态恢复许可。 */
func (l *TextLedger) ClaimTransport(ctx context.Context, verified *metondispatch.Verified, key SessionKey, hold *Hold) (bool, error) {
	if !l.currentTransport(verified, key) || !l.matchesTransport(hold, verified) {
		return false, metondispatch.ErrProof
	}
	c := verified.Context()
	conn, err := l.conn(ctx)
	if err != nil {
		return false, err
	}
	defer conn.Close()
	var first bool
	err = conn.QueryRowContext(ctx, "SELECT meton_ledger.claim_transport_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
		l.environment, l.source, l.epoch, c.User, c.Account, hold.Origin.SourceMarker, c.Caller, c.OperationID,
		hold.Origin.SourceRequestID, verified.Hash(), key.ID, key.Fingerprint).Scan(&first)
	metonobserve.Claim(metonobserve.Scope{Environment: l.environment, Source: l.source, Epoch: l.epoch}, first, err)
	if err != nil {
		return false, err
	}
	if !l.currentTransport(verified, key) {
		return false, metondispatch.ErrProof
	}
	return first, nil
}

func (l *TextLedger) currentTransport(v *metondispatch.Verified, key SessionKey) bool {
	if !l.currentSource() || !v.Current(time.Now()) || key.ID < 1 {
		return false
	}
	c := v.Context()
	return c.Environment == l.environment && c.Source == l.source && c.Epoch == l.epoch && c.KeyDigest == key.Fingerprint
}

func (l *TextLedger) matchesTransport(h *Hold, v *metondispatch.Verified) bool {
	if h == nil || v == nil {
		return false
	}
	c := v.Context()
	o := h.Origin
	return o.Environment == l.environment && o.Source == l.source && o.SourceMarker != "" && o.SourceRequestID != "" &&
		o.User == c.User && o.Account == c.Account && o.Caller == c.Caller && o.OperationID == c.OperationID && h.AcceptedEpoch == c.Epoch &&
		h.Estimate.Protocol == c.Protocol && h.Estimate.Model == c.Model && h.Estimate.DigestVersion == c.DigestVersion && h.Estimate.Digest == c.InputDigest
}
