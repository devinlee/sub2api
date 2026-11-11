-- 原账号看自己的资金进度。应付价、原交易实收和没有换成额度的现金各自保留，不从用户净余额推断。
CREATE INDEX cash_payment_original_order ON meton_ledger.cash_payments(native_order,source_marker);
CREATE INDEX cash_part_original_order ON meton_ledger.cash_parts(native_order,source_marker,basis);
CREATE INDEX cash_conflict_original_claim ON meton_ledger.cash_payment_conflicts(claimed_intent,claimed_marker);

CREATE FUNCTION meton_ledger.original_cash_review(o meton_ledger.cash_orders) RETURNS jsonb
LANGUAGE plpgsql STABLE STRICT SET search_path=pg_catalog,pg_temp AS $$
DECLARE reason text; received numeric; unposted numeric;
BEGIN
    IF EXISTS(SELECT FROM meton_ledger.cash_refund_observations r WHERE r.native_order=o.native_order AND r.source_marker=o.source_marker) THEN
        reason:='refund_notice';
    ELSIF EXISTS(SELECT FROM meton_ledger.cash_payment_conflicts c WHERE (c.claimed_intent,c.claimed_marker)=(o.intent_id,o.source_marker))
        OR EXISTS(SELECT FROM meton_ledger.cash_payments p JOIN meton_ledger.cash_payment_conflicts c USING(payment_id)
            WHERE (p.native_order,p.source_marker)=(o.native_order,o.source_marker)) THEN reason:='payment_conflict';
    ELSIF EXISTS(SELECT FROM meton_ledger.cash_parts part JOIN meton_ledger.cash_payment_dispositions d USING(payment_id)
        WHERE (part.native_order,part.source_marker,part.basis)=(o.native_order,o.source_marker,'unposted_cash') AND d.state='restricted') THEN
        reason:='unposted_cash';
    ELSE RETURN NULL; END IF;
    SELECT coalesce(sum(payer_fen),0) INTO received FROM meton_ledger.cash_payments WHERE (native_order,source_marker)=(o.native_order,o.source_marker);
    SELECT coalesce(sum(basis_fen),0) INTO unposted FROM meton_ledger.cash_parts
        WHERE (native_order,source_marker,basis)=(o.native_order,o.source_marker,'unposted_cash');
    RETURN jsonb_build_object('reason',reason,'receivedFen',received::text,'unpostedFen',unposted::text);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.original_cash_review(meton_ledger.cash_orders) FROM PUBLIC;

DO $review$
DECLARE lookup text:=pg_get_functiondef('meton_ledger.read_original_purchase(jsonb,uuid,timestamptz)'::regprocedure);
    http_def text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    dispatch text:=pg_get_functiondef('meton_ledger.claim_purchase_dispatch(jsonb,jsonb,jsonb,uuid,bytea,uuid,timestamptz)'::regprocedure);
    cancel_def text:=pg_get_functiondef('meton_ledger.cancel_original_checkout(jsonb,jsonb,jsonb,uuid,bytea,bigint,timestamptz)'::regprocedure);
    read_at constant text:='''closeState'',CASE WHEN c.native_order IS NULL';
    code_at constant text:='AND result::jsonb->>''closeState''=''open''';
    dispatch_at constant text:='IF EXISTS(SELECT FROM meton_ledger.cash_order_stops stop WHERE stop.intent_id=i)';
    cancel_at constant text:='RETURN meton_ledger.stop_original_order(o.source_marker,original,''member_cancel'');';
BEGIN
    IF cardinality(string_to_array(lookup,read_at))<>2 OR cardinality(string_to_array(http_def,code_at))<>2 OR
        cardinality(string_to_array(dispatch,dispatch_at))<>2 OR cardinality(string_to_array(cancel_def,cancel_at))<>2 THEN
        RAISE EXCEPTION 'original order review seam changed'; END IF;
    EXECUTE replace(lookup,read_at,'''cashReview'',meton_ledger.original_cash_review(c), '||read_at);
    EXECUTE replace(http_def,code_at,code_at||' AND result::jsonb->''cashReview''=''null''::jsonb');
    -- 锁住原单后复核；旧窗口持有的按钮或报价也不能为待核对订单再取得付款尝试。
    EXECUTE replace(dispatch,dispatch_at,dispatch_at||$gate$ OR EXISTS(SELECT FROM meton_ledger.cash_orders c
        WHERE c.intent_id=i AND meton_ledger.original_cash_review(c) IS NOT NULL)$gate$);
    EXECUTE replace(cancel_def,cancel_at,'IF meton_ledger.original_cash_review(o) IS NOT NULL THEN RETURN ''review''; END IF; '||cancel_at);
END $review$;
