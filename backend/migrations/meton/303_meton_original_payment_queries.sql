-- 只调度已取得派发权的原商户订单。查单没有收款权限，也不会创建新的付款尝试。
CREATE TABLE meton_ledger.cash_query_schedule(
    native_order bigint PRIMARY KEY REFERENCES meton_ledger.cash_orders,
    token uuid NOT NULL, generation bigint NOT NULL, next_query_at timestamptz NOT NULL,
    state text NOT NULL CHECK(state IN ('reading','pending','unknown','evidence','review')),
    attempts bigint NOT NULL CHECK(attempts>0)
);
CREATE INDEX cash_query_due ON meton_ledger.cash_query_schedule(next_query_at,native_order);

CREATE FUNCTION meton_ledger.claim_original_cash_query(route jsonb, window_seconds integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE o meton_ledger.cash_orders%ROWTYPE; lease uuid;
BEGIN
    PERFORM meton_ledger.require_cash_writer(route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    IF window_seconds IS NULL OR window_seconds NOT BETWEEN 60 AND 2678400 OR meton_ledger.notification_system_id()<>route->>'sourceSystem' THEN
        RAISE EXCEPTION 'cash query scope unavailable' USING ERRCODE='42501'; END IF;
    SELECT c.* INTO o FROM meton_ledger.cash_orders c JOIN meton_ledger.cash_order_attempts a USING(native_order,intent_id,source_marker)
        JOIN public.meton_managed_creations m USING(source_marker)
        LEFT JOIN meton_ledger.cash_query_schedule s USING(native_order)
        WHERE (c.channel,c.cash_environment,c.merchant_id,c.app_id,m.environment,m.source,m.epoch)=
            (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',route->>'deployment',route->>'source',(route->>'epoch')::bigint)
          AND a.dispatch_id IS NOT NULL AND a.dispatched_at <= clock_timestamp()-interval '3 seconds'
          AND coalesce(a.presentation->>'kind','')<>'declined'
          AND a.dispatched_at+make_interval(secs=>window_seconds)>clock_timestamp()
          AND NOT EXISTS(SELECT FROM meton_ledger.cash_payments p WHERE p.native_order=c.native_order)
          AND (s.native_order IS NULL OR s.next_query_at<=clock_timestamp() AND s.state NOT IN ('evidence','review'))
        ORDER BY coalesce(s.next_query_at,a.dispatched_at),c.native_order LIMIT 1 FOR UPDATE OF c SKIP LOCKED;
    IF NOT FOUND THEN RETURN NULL; END IF;
    INSERT INTO meton_ledger.cash_query_schedule AS s(native_order,token,generation,next_query_at,state,attempts)
        VALUES(o.native_order,gen_random_uuid(),(route->>'epoch')::bigint,clock_timestamp()+interval '30 seconds','reading',1)
        ON CONFLICT(native_order) DO UPDATE SET token=excluded.token,generation=excluded.generation,next_query_at=excluded.next_query_at,
            state='reading',attempts=s.attempts+1 WHERE s.next_query_at<=clock_timestamp() AND s.state NOT IN ('evidence','review')
        RETURNING token INTO lease;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('intent',o.intent_id,'marker',o.source_marker,'token',lease,'order',o.out_trade_no,
        'priceFen',o.price_fen,'paramsHash',o.params_hash);
END $$;

CREATE FUNCTION meton_ledger.finish_original_cash_query(route jsonb, original uuid, marker uuid, lease uuid, result text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.require_cash_writer(route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    IF result IS NULL OR result NOT IN ('pending','unknown','evidence','review') OR meton_ledger.notification_system_id()<>route->>'sourceSystem' THEN
        RAISE EXCEPTION 'invalid cash query result' USING ERRCODE='22023'; END IF;
    UPDATE meton_ledger.cash_query_schedule s SET state=result,next_query_at=clock_timestamp()+interval '30 seconds'
        FROM meton_ledger.cash_orders o WHERE s.native_order=o.native_order AND s.token=lease AND s.state='reading'
        AND (o.intent_id,o.source_marker,o.channel,o.cash_environment,o.merchant_id,o.app_id,s.generation)=
        (original,marker,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',(route->>'epoch')::bigint);
    RETURN FOUND;
END $$;
REVOKE ALL ON meton_ledger.cash_query_schedule FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.claim_original_cash_query(jsonb,integer),
    meton_ledger.finish_original_cash_query(jsonb,uuid,uuid,uuid,text) FROM PUBLIC;
