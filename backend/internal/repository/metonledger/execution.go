//go:build meton_managed

package metonledger

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
)

/** ReserveExecution 同事务登记原生转换后的规格与原 H；只接受已核验的部署报价。 */
func (l *TextLedger) ReserveExecution(ctx context.Context, v *metondispatch.Verified, key SessionKey, quote *metonexecution.Quote) (*Hold, error) {
	return l.reserveExecution(ctx, v, key, quote, nil)
}

/** ReserveProviderExecution 与原预占同事务保存最终供应绑定，提交未知不领取发送权。 */
func (l *TextLedger) ReserveProviderExecution(ctx context.Context, v *metondispatch.Verified, key SessionKey, quote *metonexecution.Quote, binding metonprovider.Binding) (*Hold, error) {
	if !binding.Valid() {
		return nil, metonexecution.ErrExecution
	}
	return l.reserveExecution(ctx, v, key, quote, &binding)
}

func (l *TextLedger) reserveExecution(ctx context.Context, v *metondispatch.Verified, key SessionKey, quote *metonexecution.Quote, binding *metonprovider.Binding) (*Hold, error) {
	if !l.currentTransport(v, key) || !quote.For(v) {
		return nil, metonexecution.ErrExecution
	}
	c := v.Context()
	spec := quote.Record()
	raw, _ := json.Marshal(c)
	encoded, _ := json.Marshal(spec)
	conn, err := l.conn(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	// 原生文本路径也必须核对持久账户保护，不能只保护直接预占入口。
	if err = requireAccountLimit(ctx, conn); err != nil {
		return nil, err
	}
	query := "reserve_execution_text($1,$2,$3,$4,$5,$6,$7,$8)"
	args := []any{l.environment, l.source, l.epoch, string(raw), v.Hash(), v.Service(), key.ID, string(encoded)}
	if binding != nil {
		provider, _ := json.Marshal(binding)
		args = append(args, string(provider))
		query = "reserve_provider_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9)"
	}
	h, err := scanHold(conn.QueryRowContext(ctx, holdColumns+query, args...))
	if err != nil {
		return nil, err
	}
	if !l.matchesTransport(h, v) || h.Estimate.InputBound != spec.InputBound || h.Estimate.OutputBound != spec.OutputBound {
		return nil, errors.New("different original execution receipt")
	}
	if !l.currentTransport(v, key) {
		return nil, metonexecution.ErrExecution
	}
	return h, nil
}

/** ClaimExecution 复验同一实际规格；确定首次提交以外的结果均不能触发网络或释放 H。 */
func (l *TextLedger) ClaimExecution(ctx context.Context, v *metondispatch.Verified, key SessionKey, h *Hold, quote *metonexecution.Quote) (bool, error) {
	if !l.currentTransport(v, key) || !l.matchesTransport(h, v) || !quote.For(v) {
		return false, metonexecution.ErrExecution
	}
	c := v.Context()
	spec := quote.Record()
	if h.Estimate.InputBound != spec.InputBound || h.Estimate.OutputBound != spec.OutputBound {
		return false, metonexecution.ErrExecution
	}
	raw, _ := json.Marshal(spec)
	conn, err := l.conn(ctx)
	if err != nil {
		return false, err
	}
	defer conn.Close()
	var first bool
	err = conn.QueryRowContext(ctx, "SELECT meton_ledger.claim_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
		l.environment, l.source, l.epoch, c.User, c.Account, h.Origin.SourceMarker, c.Caller, c.OperationID, h.Origin.SourceRequestID,
		v.Hash(), key.ID, key.Fingerprint, string(raw)).Scan(&first)
	metonobserve.Claim(metonobserve.Scope{Environment: l.environment, Source: l.source, Epoch: l.epoch}, first, err)
	if err != nil {
		return false, err
	}
	if !l.currentTransport(v, key) {
		return false, metonexecution.ErrExecution
	}
	return first, nil
}
