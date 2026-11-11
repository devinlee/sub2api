-- 已释放只说明原占用结束，不能证明每份迟到通知均已处理；关闭通知必须匹配原失败释放凭证。
DO $released_notice$
DECLARE body text:=pg_get_functiondef('meton_ledger.cash_notice_original(jsonb,jsonb)'::regprocedure);
    before_branch text:=$before$    IF r.phase='settled' THEN
        observed:=(o.native_order,m.source_marker,o.channel,o.cash_environment,o.merchant_id,p.channel_transaction,
            sha256(convert_to((facts-'delivery')::text,'UTF8')),facts-'delivery')::meton_ledger.cash_refund_observations;$before$;
    released_branch text:=$released$    ELSIF r.phase='released' AND facts->>'state' NOT IN ('CLOSED','ABNORMAL') THEN RETURN;$released$;
BEGIN
    IF cardinality(string_to_array(body,before_branch))<>2 OR cardinality(string_to_array(body,released_branch))<>2 THEN
        RAISE EXCEPTION 'notice original release comparison changed'; END IF;
    body:=replace(body,before_branch,$after$    observed:=(o.native_order,m.source_marker,o.channel,o.cash_environment,o.merchant_id,p.channel_transaction,
        sha256(convert_to((facts-'delivery')::text,'UTF8')),facts-'delivery')::meton_ledger.cash_refund_observations;
    IF r.phase='settled' THEN$after$);
    -- 复用同一原退款的已核实关闭事实；停止、未发送或 ABNORMAL 都不能替代渠道关闭证明。
    EXECUTE replace(body,released_branch,$verified$    ELSIF r.phase='released' THEN
        IF NOT meton_ledger.refund_observation_resolved(observed) THEN RETURN; END IF;$verified$);
END $released_notice$;
