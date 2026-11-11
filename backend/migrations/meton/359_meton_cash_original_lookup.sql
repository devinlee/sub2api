-- 本机编号丢失时仅返回本人的原确认意图，仍沿既有只读退款接口复验身份；不创建资金或授权事实。
DO $original_lookup$
DECLARE body text:=pg_get_functiondef('meton_ledger.cash_statement_item(jsonb,jsonb)'::regprocedure);
    needle text:='''units'',''cashConfirmed'',''sourceSettled'',''recoveryConfirmed'']);';
    addition text:=$append$
        result:=result||coalesce((SELECT jsonb_build_object('intent',d.intent_id)
            FROM meton_ledger.cash_refund_decisions d WHERE d.refund_id::text=ref
                AND d.source_marker=(owner->>'source_marker')::uuid AND d.state='accepted'),'{}'::jsonb);
    $append$;
BEGIN
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'cash statement refund fields changed'; END IF;
    IF strpos(body,needle||addition)>0 THEN RETURN; END IF;
    EXECUTE replace(body,needle,needle||addition);
END $original_lookup$;
