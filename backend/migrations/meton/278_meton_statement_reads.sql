-- 只读查询沿原资金事件和恢复栅栏；迁移不创建钱包、快照任务、权限或资金效果。
CREATE FUNCTION meton_ledger.statement_owner(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid)
RETURNS public.meton_managed_creations LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE;
BEGIN
    -- 每次 HTTP 读取对应一个新语句快照，不能在恢复或备用库上延续旧读取权限。
    IF current_setting('transaction_isolation')<>'read committed' OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin'
        OR NOT EXISTS(SELECT FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch) THEN
        RAISE EXCEPTION 'current statement source unavailable' USING ERRCODE='55000'; END IF;
    SELECT c.* INTO m FROM public.meton_managed_creations c
        JOIN public.meton_s1_funds_births b ON b.remote_user=c.remote_user AND b.operation=c.operation
        JOIN public.users u ON u.id=c.remote_user
        WHERE ROW(c.environment,c.source,c.epoch,c.meton_user,c.account,c.operation,c.dispatch,c.remote_user,c.source_marker)
            IS NOT DISTINCT FROM ROW(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker)
          AND u.deleted_at IS NULL AND u.role='user' AND u.restrict_public_groups AND u.password_hash='!meton-managed'
          AND u.email='meton-'||c.account::text||'@managed.invalid';
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original statement owner' USING ERRCODE='42501'; END IF;
    RETURN m;
END $$;

CREATE FUNCTION meton_ledger.statement_window(p_from date,p_through date) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF p_from IS NULL OR p_through IS NULL OR p_from<date '1970-01-01' OR p_through<p_from OR p_through-p_from>30
        OR p_through>(statement_timestamp() AT TIME ZONE 'UTC')::date THEN
        RAISE EXCEPTION 'invalid statement window' USING ERRCODE='22023'; END IF;
END $$;

CREATE FUNCTION meton_ledger.open_statement(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,
    p_from date,p_through date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; u public.users%ROWTYPE; a meton_ledger.accounts%ROWTYPE;
    cut bigint; tip uuid; native numeric; stock numeric; held numeric; refunds numeric; gift numeric; bought numeric;
    gh numeric; ph numeric; pr numeric; all_count bigint; net numeric; opening numeric; period_net numeric; closing numeric; period_count bigint;
    chain_ok boolean; largest bigint; gap numeric; pending bigint; key_count bigint; incompatible bigint; zero numeric(20,8):=0;
BEGIN
    m=meton_ledger.statement_owner(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker);
    PERFORM meton_ledger.statement_window(p_from,p_through);
    SELECT * INTO STRICT u FROM public.users WHERE id=p_remote;
    SELECT * INTO a FROM meton_ledger.accounts WHERE source_marker=p_marker;
    cut=coalesce(a.last_sequence,0);native=u.balance;
    -- STABLE 的所有读取共享调用语句快照；H 变化即使不增资金序号，也与本次汇总在同一时点。
    WITH journal AS (
        SELECT e.*,lag(e.balance_after,1,zero) OVER(ORDER BY e.sequence) AS previous_balance
        FROM meton_ledger.events e WHERE e.source_marker=p_marker
    )
    SELECT count(*),coalesce(sum(amount),0),coalesce(max(sequence),0),coalesce(bool_and(balance_before=previous_balance),true),
        coalesce(sum(amount) FILTER(WHERE recorded_at<(p_from::timestamp AT TIME ZONE 'UTC')),0),
        coalesce(sum(amount) FILTER(WHERE recorded_at>=(p_from::timestamp AT TIME ZONE 'UTC') AND recorded_at<((p_through+1)::timestamp AT TIME ZONE 'UTC')),0),
        coalesce(sum(amount) FILTER(WHERE recorded_at<((p_through+1)::timestamp AT TIME ZONE 'UTC')),0),
        count(*) FILTER(WHERE recorded_at>=(p_from::timestamp AT TIME ZONE 'UTC') AND recorded_at<((p_through+1)::timestamp AT TIME ZONE 'UTC'))
        INTO all_count,net,largest,chain_ok,opening,period_net,closing,period_count FROM journal;
    SELECT event_id INTO tip FROM meton_ledger.events WHERE source_marker=p_marker AND sequence=cut AND balance_after=native;
    SELECT coalesce(sum(l.remaining),0),coalesce(sum(l.held),0),coalesce(sum(l.refund_held),0),
        coalesce(sum(l.remaining) FILTER(WHERE e.kind='grant'),0),coalesce(sum(l.remaining) FILTER(WHERE e.kind='purchase'),0),
        coalesce(sum(l.held) FILTER(WHERE e.kind='grant'),0),coalesce(sum(l.held) FILTER(WHERE e.kind='purchase'),0),
        coalesce(sum(l.refund_held) FILTER(WHERE e.kind='purchase'),0)
        INTO stock,held,refunds,gift,bought,gh,ph,pr
        FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=p_marker;
    IF all_count<>cut OR largest<>cut OR NOT chain_ok OR stock<>native OR net<>native OR gift+bought<>stock OR gh+ph<>held OR pr<>refunds
        OR native<held+refunds OR u.frozen_balance<>0 OR cut>0 AND tip IS NULL OR opening+period_net<>closing THEN
        RAISE EXCEPTION 'statement source requires reconciliation' USING ERRCODE='55000'; END IF;
    SELECT coalesce(sum(f.uncovered),0) INTO gap FROM meton_ledger.text_requests r JOIN meton_ledger.latest_text_fees f USING(request_id)
        WHERE r.source_marker=p_marker;
    SELECT count(*) INTO pending FROM meton_ledger.text_requests r WHERE r.source_marker=p_marker
        AND NOT EXISTS(SELECT FROM meton_ledger.text_send_decisions d WHERE d.request_id=r.request_id AND d.state='cancelled_unsent')
        AND NOT EXISTS(SELECT FROM meton_ledger.text_fee_endings e WHERE e.request_id=r.request_id);
    -- 原生金额计数不是第二份可消费额度；只观察当前可用托管 Key 是否仍符合原 M11 零计数约束。
    SELECT count(*),count(*) FILTER(WHERE k.quota IS DISTINCT FROM zero OR k.quota_used IS DISTINCT FROM zero OR
        k.rate_limit_5h IS DISTINCT FROM zero OR k.rate_limit_1d IS DISTINCT FROM zero OR k.rate_limit_7d IS DISTINCT FROM zero OR
        k.usage_5h IS DISTINCT FROM zero OR k.usage_1d IS DISTINCT FROM zero OR k.usage_7d IS DISTINCT FROM zero OR k.expires_at IS NULL)
        INTO key_count,incompatible FROM public.meton_managed_keys x JOIN public.api_keys k ON k.id=x.remote_key
        WHERE x.source_marker=p_marker AND x.meton_user=p_user AND x.claim->'origin'->>'epoch'=p_epoch::text AND k.deleted_at IS NULL AND k.status='active'
          AND (k.expires_at IS NULL OR k.expires_at>statement_timestamp());
    RETURN jsonb_build_object('version',1,'state',CASE WHEN cut=0 THEN 'empty' ELSE 'observed' END,
        'origin',jsonb_build_object('environment',p_env,'source',p_source,'epoch',p_epoch,'user',p_user,'account',p_account,
            'creation',p_creation,'dispatch',p_dispatch,'remote_user',p_remote,'source_marker',p_marker),
        'cut',jsonb_build_object('sequence',cut,'event',tip,'observed_at',statement_timestamp()),
        'period',jsonb_build_object('from',p_from,'through',p_through,'unit',a.unit,'opening',opening::numeric(20,8)::text,
            'net',period_net::numeric(20,8)::text,'closing',closing::numeric(20,8)::text,'events',period_count),
        'funds',jsonb_build_object('unit',a.unit,'balance',stock::numeric(20,8)::text,'held',held::numeric(20,8)::text,
            'refund_held',refunds::numeric(20,8)::text,'available',(stock-held-refunds)::numeric(20,8)::text,'shortfall',gap::numeric(20,8)::text,
            'gift',jsonb_build_object('remaining',gift::numeric(20,8)::text,'held',gh::numeric(20,8)::text,'refund_held',zero::text,'available',(gift-gh)::numeric(20,8)::text),
            'purchase',jsonb_build_object('remaining',bought::numeric(20,8)::text,'held',ph::numeric(20,8)::text,'refund_held',pr::numeric(20,8)::text,'available',(bought-ph-pr)::numeric(20,8)::text)),
        'limits',jsonb_build_object('scope','source_account_all_sessions','concurrency',u.concurrency,'pending',pending,
            'key_budget','shared_account','key_policy','native_amount_counters_zero_only','current_keys',key_count,'unsupported_keys',incompatible));
END $$;

CREATE FUNCTION meton_ledger.statement_parts(p_event uuid)
RETURNS TABLE(gift_delta numeric,purchase_delta numeric,valid boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    WITH original AS (SELECT * FROM meton_ledger.events WHERE event_id=p_event),
    portions AS (
        SELECT e.event_id AS credit,e.amount AS delta FROM original e WHERE e.kind IN ('grant','purchase')
        UNION ALL
        SELECT s.credit_event,-s.charged FROM original e JOIN meton_ledger.text_postings p ON p.journal_event=e.event_id
            JOIN meton_ledger.text_spend_splits s ON s.report_event=p.report_event WHERE e.kind IN ('text_charge','text_revision')
        UNION ALL
        SELECT (line.value->>'credit_event')::uuid,(line.value->>'amount')::numeric FROM original e
            JOIN meton_ledger.text_corrections c ON c.journal=e.event_id JOIN meton_ledger.text_correction_decisions d USING(decision)
            CROSS JOIN LATERAL jsonb_array_elements(d.sources) line(value) WHERE e.kind='text_correction'
        UNION ALL
        SELECT r.credit_event,-r.amount FROM original e JOIN meton_ledger.gift_retirements r ON r.journal=e.event_id WHERE e.kind='gift_termination'
    )
    SELECT coalesce(sum(p.delta) FILTER(WHERE c.kind='grant'),0),coalesce(sum(p.delta) FILTER(WHERE c.kind='purchase'),0),
        count(*)>0 AND sum(p.delta)=(SELECT amount FROM original) AND
        coalesce(bool_and(c.event_id IS NOT NULL AND c.source_marker=(SELECT source_marker FROM original) AND c.kind IN ('grant','purchase')),false)
        FROM portions p LEFT JOIN meton_ledger.events c ON c.event_id=p.credit
$$;

CREATE FUNCTION meton_ledger.read_statement_page(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,
    p_from date,p_through date,p_cut bigint,p_tip uuid,p_after bigint,p_size integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; unit text; actual bigint; items jsonb; valid boolean; last_seen bigint; count_page integer; more boolean;
BEGIN
    m=meton_ledger.statement_owner(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker);
    PERFORM meton_ledger.statement_window(p_from,p_through);
    IF p_cut IS NULL OR p_cut<0 OR p_after IS NULL OR p_after<0 OR p_after>p_cut OR p_size IS NULL OR p_size<1 OR p_size>100 OR
        (p_cut=0 AND p_tip IS NOT NULL) OR (p_cut>0 AND (p_tip IS NULL OR p_tip='00000000-0000-0000-0000-000000000000'::uuid)) THEN
        RAISE EXCEPTION 'invalid original statement cursor' USING ERRCODE='22023'; END IF;
    SELECT a.unit,a.last_sequence INTO unit,actual FROM meton_ledger.accounts a WHERE a.source_marker=p_marker;
    IF p_cut>coalesce(actual,0) OR p_cut<>(SELECT count(*) FROM meton_ledger.events WHERE source_marker=p_marker AND sequence<=p_cut)
        OR p_cut>0 AND NOT EXISTS(SELECT FROM meton_ledger.events WHERE source_marker=p_marker AND sequence=p_cut AND event_id=p_tip) THEN
        RAISE EXCEPTION 'original statement cutoff missing' USING ERRCODE='23505'; END IF;
    -- 原空截点仍为空，后来建立的单位和余额不能混入它；新读取重新取完整头。
    IF p_cut=0 THEN unit=NULL; END IF;
    WITH page AS (
        SELECT e.* FROM meton_ledger.events e WHERE e.source_marker=p_marker AND e.sequence>p_after AND e.sequence<=p_cut
            AND e.recorded_at>=(p_from::timestamp AT TIME ZONE 'UTC') AND e.recorded_at<((p_through+1)::timestamp AT TIME ZONE 'UTC')
            ORDER BY e.sequence LIMIT p_size
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('event',e.event_id,'sequence',e.sequence,'kind',e.kind,'operation',e.operation_id,
        'origin',e.origin_ref,'amount',e.amount::text,'balance_before',e.balance_before::text,'balance_after',e.balance_after::text,'recorded_at',e.recorded_at,
        'gift_delta',p.gift_delta::numeric(20,8)::text,'purchase_delta',p.purchase_delta::numeric(20,8)::text) ORDER BY e.sequence),'[]'::jsonb),
        coalesce(bool_and(p.valid),true),coalesce(max(e.sequence),p_after),count(*)
        INTO items,valid,last_seen,count_page FROM page e CROSS JOIN LATERAL meton_ledger.statement_parts(e.event_id) p;
    IF NOT valid THEN RAISE EXCEPTION 'original statement allocation incomplete' USING ERRCODE='55000'; END IF;
    SELECT EXISTS(SELECT FROM meton_ledger.events e WHERE e.source_marker=p_marker AND e.sequence>last_seen AND e.sequence<=p_cut
        AND e.recorded_at>=(p_from::timestamp AT TIME ZONE 'UTC') AND e.recorded_at<((p_through+1)::timestamp AT TIME ZONE 'UTC')) INTO more;
    RETURN jsonb_build_object('version',1,'origin',jsonb_build_object('environment',p_env,'source',p_source,'epoch',p_epoch,'user',p_user,'account',p_account,
            'creation',p_creation,'dispatch',p_dispatch,'remote_user',p_remote,'source_marker',p_marker),
        'cut',jsonb_build_object('sequence',p_cut,'event',p_tip),'period',jsonb_build_object('from',p_from,'through',p_through,'unit',unit),
        'after',p_after,'size',p_size,'last',last_seen,'count',count_page,'more',more,'items',items);
END $$;

REVOKE ALL ON FUNCTION meton_ledger.statement_owner(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid),meton_ledger.statement_window(date,date),
    meton_ledger.open_statement(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,date,date),meton_ledger.statement_parts(uuid),
    meton_ledger.read_statement_page(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,date,date,bigint,uuid,bigint,integer) FROM PUBLIC;
