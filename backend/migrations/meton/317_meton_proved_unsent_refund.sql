-- 已领取初始资格、但所有者在实际发送开始前永久交回时，恢复那一笔的原冻结。
-- 只有截点外能够签发 unsent。只有 retired 表明发送者已停止，现金结果仍未知。
DO $unsent$
DECLARE src text:=pg_get_functiondef('meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb)'::regprocedure);
    choices constant text:='choice NOT IN (''stopped'',''claimed'')';
    current_phase constant text:='IF r.phase<>''held'' THEN RETURN r.phase; END IF;';
    current_version constant text:='IF r.disposition_version<>1 OR EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries';
BEGIN
    IF cardinality(string_to_array(src,choices))<>2 OR cardinality(string_to_array(src,current_phase))<>2 OR
        cardinality(string_to_array(src,current_version))<>2 THEN RAISE EXCEPTION 'original refund release changed'; END IF;
    src:=replace(src,choices,'choice NOT IN (''stopped'',''claimed'',''unsent'')');
    src:=replace(src,current_phase,'IF r.phase<>''held'' AND NOT (choice=''unsent'' AND r.phase IN (''possibly_sent'',''unknown'')) THEN RETURN r.phase; END IF;');
    EXECUTE replace(src,current_version,'IF (r.phase=''held'' AND r.disposition_version<>1 OR r.phase<>''held'' AND r.disposition_version<2) OR EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries');
END $unsent$;

-- 发送资格可能已领但实际传输从未开始。显式取消仍可从截点外接回已经提交的未发证明。
DO $resume_stop$
DECLARE src text:=pg_get_functiondef('meton_ledger.prepare_refund_cancel(jsonb,jsonb,uuid,uuid,bigint,timestamptz)'::regprocedure);
    phase_at constant text:='IF value->>''phase''<>''held'' THEN';
    version_at constant text:='IF (value->>''version'')::bigint<>expected_version THEN';
BEGIN
    IF cardinality(string_to_array(src,phase_at))<>2 OR cardinality(string_to_array(src,version_at))<>2 THEN
        RAISE EXCEPTION 'original member refund version check changed'; END IF;
    src:=replace(src,phase_at,'IF expected_version>(value->>''version'')::bigint THEN RAISE EXCEPTION ''refund version differs'' USING ERRCODE=''23505''; END IF;
    IF value->>''phase'' NOT IN (''held'',''possibly_sent'',''unknown'') THEN');
    EXECUTE replace(src,version_at,'IF value->>''phase''=''held'' AND (value->>''version'')::bigint<>expected_version THEN');
END $resume_stop$;
