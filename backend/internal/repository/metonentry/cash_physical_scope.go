//go:build meton_managed

package metonentry

import (
    "context"
    "encoding/json"
    "time"
)

const restoredCashProofScope = "meton_ledger.restored_cash_proof_scope(text,text,bigint,text,text,bigint,text,jsonb)"

/** 物理标识改变只沿当前来源中的原恢复链核实，不能把密钥可解封或较小代次当成授权。 */
func (w *purchaseWorker) historicalPhysicalScope(source, inbox string, epoch int64, origin json.RawMessage) *purchaseOutcome {
    c := w.n.cfg
    if epoch < 1 || epoch > c.Epoch {
        return &purchaseOutcome{"review", "recovery_scope"}
    }
    if source == c.SourceSystem && inbox == c.InboxSystem {
        return nil
    }
    if w.source == nil {
        return &purchaseOutcome{"review", "recovery_scope"}
    }
    // 原密文解析原先是纯函数；新增读取有独立短期限，不让一个历史证明占满处理队列。
    ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
    defer cancel()
    var permitted bool
    err := w.source.QueryRowContext(ctx, "SELECT meton_ledger.restored_cash_proof_scope($1,$2,$3,$4,$5,$6,$7,$8)",
        c.Environment, c.Source, c.Epoch, source, inbox, epoch, c.InboxSystem, string(origin)).Scan(&permitted)
    if err != nil {
        return &purchaseOutcome{"retry", "recovery_authority_unconfirmed"}
    }
    if !permitted {
        return &purchaseOutcome{"review", "recovery_scope"}
    }
    return nil
}
