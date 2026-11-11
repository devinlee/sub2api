-- 恢复代次已换而原资金处置未补齐时，当前验签成功仍不能证明这笔钱从未履约或退回。
-- 此处只返回待核对，不写另一份恢复余额；完整原材料的接续沿原恢复流程。
CREATE FUNCTION meton_ledger.original_purchase_generation(o meton_ledger.cash_orders,generation bigint) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.checkout_handoffs h WHERE
        (h.intent_id,h.source_marker)=(o.intent_id,o.source_marker) AND (h.origin->>'epoch')::bigint=generation)
$$;
REVOKE ALL ON FUNCTION meton_ledger.original_purchase_generation(meton_ledger.cash_orders,bigint) FROM PUBLIC;
DO $original$
DECLARE body text; needle text;
BEGIN
    body:=pg_get_functiondef('meton_ledger.observe_cash_payment(text,text,bigint,jsonb,jsonb)'::regprocedure);
    needle:='first_payment:=NOT EXISTS(SELECT FROM meton_ledger.cash_order_awards';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'original cash observation changed'; END IF;
    EXECUTE replace(body,needle,$missing$IF NOT meton_ledger.original_purchase_generation(o,generation) THEN
        RETURN jsonb_build_object('state','recovery_review'); END IF;
        $missing$||needle);
    body:=pg_get_functiondef('meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)'::regprocedure);
    needle:='RETURN jsonb_build_object(''state'',''posted'',''payment'',payment,''event'',effect.event_id,''sequence'',effect.sequence);
    END IF;';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'original purchase disposition changed'; END IF;
    -- 已保留的购买事件在本判断之前按原号返回；绝不按用户余额判断是否需要再次入账。
    EXECUTE replace(body,needle,needle||$missing$
    IF NOT meton_ledger.original_purchase_generation(o,generation) THEN
        RETURN jsonb_build_object('state','recovery_review','payment',payment,'version',d.version); END IF;
        $missing$);
END $original$;
