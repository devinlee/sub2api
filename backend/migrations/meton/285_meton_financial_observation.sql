-- 财务取样只读原批次和原请求，不创建资金缓存、修复记录或新的发送资格。
CREATE FUNCTION meton_ledger.read_financial_observation(p_env text,p_source text,p_epoch bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE observed timestamptz:=statement_timestamp(); groups jsonb; account_count bigint; historical_count bigint;
BEGIN
    IF num_nulls(p_env,p_source,p_epoch)>0 OR p_env !~ '^[A-Za-z0-9_.-]{1,120}$' OR
        p_source !~ '^[A-Za-z0-9_.-]{1,120}$' OR p_epoch<1 THEN
        RAISE EXCEPTION 'invalid financial observation scope' USING ERRCODE='22023'; END IF;
    -- 禁止复用恢复前事务快照；协作方必须在语句开始前设置真实查询期限。
    IF current_setting('transaction_isolation')<>'read committed' OR current_setting('transaction_read_only')<>'on' OR
        current_setting('statement_timeout')::interval NOT BETWEEN interval '1 millisecond' AND interval '5 seconds' OR
        pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR
        NOT EXISTS(SELECT FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch) THEN
        RAISE EXCEPTION 'current financial observation unavailable' USING ERRCODE='55000'; END IF;
    IF pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_ledger','CREATE') THEN
        RAISE EXCEPTION 'restricted financial reader required' USING ERRCODE='42501'; END IF;

    -- 不把恢复前、已注销或待接续的来源过滤掉。任何未来代次或原金额不守恒都不能伪装成健康零值。
    IF EXISTS(
        SELECT FROM public.meton_managed_creations m LEFT JOIN public.users u ON u.id=m.remote_user
        LEFT JOIN meton_ledger.accounts a USING(source_marker)
        LEFT JOIN LATERAL (SELECT sum(l.remaining) AS balance FROM meton_ledger.events e
            JOIN meton_ledger.lots l ON l.credit_event=e.event_id WHERE e.source_marker=m.source_marker) stock ON true
        WHERE m.environment=p_env AND m.source=p_source AND
            (m.epoch>p_epoch OR u.id IS NULL OR u.balance<>coalesce(stock.balance,0) OR u.frozen_balance<>0 OR
             a.source_marker IS NULL AND coalesce(stock.balance,0)<>0)) OR EXISTS(
        SELECT FROM meton_ledger.text_requests r JOIN public.meton_managed_creations m USING(source_marker)
        JOIN meton_ledger.accounts a USING(source_marker)
        JOIN meton_ledger.text_prices p ON (p.environment,p.source,p.protocol,p.model,p.version)=(r.environment,r.source,r.protocol,r.model,r.price_version)
        WHERE (m.environment=p_env AND m.source=p_source OR r.environment=p_env AND r.source=p_source) AND
            ((r.environment,r.source) IS DISTINCT FROM (m.environment,m.source) OR r.epoch_at_accept>p_epoch OR p.unit<>a.unit)) THEN
        RAISE EXCEPTION 'financial observation requires reconciliation' USING ERRCODE='55000'; END IF;
    IF (SELECT count(DISTINCT a.unit) FROM meton_ledger.accounts a JOIN public.meton_managed_creations m USING(source_marker)
        WHERE m.environment=p_env AND m.source=p_source)>16 THEN
        RAISE EXCEPTION 'financial observation unit limit exceeded' USING ERRCODE='54000'; END IF;

    SELECT count(*),count(*) FILTER(WHERE epoch<p_epoch) INTO account_count,historical_count
        FROM public.meton_managed_creations WHERE environment=p_env AND source=p_source;
    -- STABLE 各读取共享同一语句快照。先按各自事实聚合再连接，避免费项、批次和请求互相放大。
    WITH origins AS MATERIALIZED (
        SELECT m.source_marker,a.unit FROM public.meton_managed_creations m JOIN meton_ledger.accounts a USING(source_marker)
        WHERE m.environment=p_env AND m.source=p_source
    ), units AS (SELECT DISTINCT unit FROM origins), funds AS (
        SELECT o.unit,sum(l.held) AS held,sum(l.held) FILTER(WHERE e.kind='grant') AS gift_held,
            sum(l.held) FILTER(WHERE e.kind='purchase') AS purchase_held,sum(l.refund_held) AS refund_held
        FROM origins o JOIN meton_ledger.events e USING(source_marker) JOIN meton_ledger.lots l ON l.credit_event=e.event_id GROUP BY o.unit
    ), requests AS MATERIALIZED (
        SELECT o.unit,r.request_id,r.accepted_at,r.epoch_at_accept,d.state,
            (d.state IS DISTINCT FROM 'cancelled_unsent' AND ending.request_id IS NULL) AS pending,
            c.observation->>'execution'='unknown' AS unknown_result,c.observation->>'fee_ready'='false' AS unknown_fee
        FROM origins o JOIN meton_ledger.text_requests r USING(source_marker)
        LEFT JOIN meton_ledger.text_send_decisions d USING(request_id)
        LEFT JOIN meton_ledger.text_fee_endings ending USING(request_id)
        LEFT JOIN meton_ledger.text_completions c USING(request_id)
    ), activity AS (
        SELECT unit,count(*) FILTER(WHERE pending) AS pending,
            count(*) FILTER(WHERE pending AND state='dispatch_claimed') AS dispatched,
            count(*) FILTER(WHERE pending AND unknown_result) AS unknown_results,
            count(*) FILTER(WHERE pending AND unknown_fee) AS unknown_fees,
            count(*) FILTER(WHERE pending AND epoch_at_accept<p_epoch) AS historical_pending,
            greatest(0,floor(extract(epoch FROM observed-min(accepted_at) FILTER(WHERE pending))*1000))::bigint AS oldest_pending_ms
        FROM requests GROUP BY unit
    ), gaps AS (
        -- 只取原权威的最新费项；覆盖修订与消费纠正不能让历史版本再次计入当前差额。
        SELECT r.unit,sum(f.uncovered) AS shortfall,count(*) FILTER(WHERE f.uncovered>0) AS shortfall_items
        FROM requests r JOIN meton_ledger.latest_text_fees f USING(request_id) GROUP BY r.unit
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('unit',u.unit,
        'held',coalesce(f.held,0)::numeric(38,8)::text,'gift_held',coalesce(f.gift_held,0)::numeric(38,8)::text,
        'purchase_held',coalesce(f.purchase_held,0)::numeric(38,8)::text,'refund_held',coalesce(f.refund_held,0)::numeric(38,8)::text,
        'shortfall',coalesce(g.shortfall,0)::numeric(38,8)::text,'shortfall_items',coalesce(g.shortfall_items,0),
        'pending_requests',coalesce(a.pending,0),'dispatched_unsettled',coalesce(a.dispatched,0),
        'unknown_results',coalesce(a.unknown_results,0),'unknown_fees',coalesce(a.unknown_fees,0),
        'historical_pending',coalesce(a.historical_pending,0),'oldest_pending_ms',coalesce(a.oldest_pending_ms,0)) ORDER BY u.unit),'[]'::jsonb)
    INTO groups FROM units u LEFT JOIN funds f USING(unit) LEFT JOIN activity a USING(unit) LEFT JOIN gaps g USING(unit);
    IF clock_timestamp()>=observed+interval '5 seconds' THEN
        RAISE EXCEPTION 'financial observation expired' USING ERRCODE='57014'; END IF;
    RETURN jsonb_build_object('version',1,'state','observed','scope',jsonb_build_object('environment',p_env,'source',p_source,'epoch',p_epoch),
        'snapshot',jsonb_build_object('observed_at',observed,'valid_until',observed+interval '5 seconds'),
        'accounts',account_count,'historical_accounts',historical_count,'units',groups);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_financial_observation(text,text,bigint) FROM PUBLIC;
