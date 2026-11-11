-- 扩展原现金环境，不改写原策略、退款、占用或凭据；原不可变事实触发器保持。
ALTER TABLE meton_ledger.refund_dispatch_policies
    DROP CONSTRAINT refund_dispatch_policies_cash_environment_check,
    ADD CONSTRAINT refund_dispatch_policies_cash_environment_check CHECK(cash_environment IN ('isolated','live'));
