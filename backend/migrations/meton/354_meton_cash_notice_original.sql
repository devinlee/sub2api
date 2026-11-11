-- 通知索引只提供查找线索。原账号、原报价及渠道经济字段必须在当前来源重新匹配，不能把归档投递号当成资金主键。
CREATE FUNCTION meton_ledger.cash_notice_original(route jsonb,link jsonb)
RETURNS TABLE(marker uuid,original_key text)
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE o meton_ledger.cash_orders; m public.meton_managed_creations; p meton_ledger.cash_payments; r meton_ledger.cash_refunds;
    original jsonb:=link->'origin'; facts jsonb:=link->'notice'; actual jsonb; observed meton_ledger.cash_refund_observations;
    bound text[]:=ARRAY['payment','part','refund','refundIntent','refundOrder','basis','requestedFen','requestedUnits'];
BEGIN
    IF (link->>'kind'='notice' AND link->>'noticeKind' IN ('payment','payment_query','refund')
        AND jsonb_typeof(original)='object' AND jsonb_typeof(facts)='object'
        AND (original->>'channel',original->>'cashEnvironment',original->>'merchant')=
            (route->>'channel',route->>'cashEnvironment',route->>'merchant')) IS NOT TRUE THEN RETURN; END IF;
    SELECT * INTO o FROM meton_ledger.cash_orders WHERE (intent_id,source_marker)=
        ((original->>'intent')::uuid,(original->>'sourceMarker')::uuid);
    IF o.intent_id IS NULL THEN RETURN; END IF;
    SELECT * INTO m FROM public.meton_managed_creations WHERE
        (environment,source,epoch,source_marker,remote_user,meton_user,account,operation)=
        (route->>'deployment',route->>'source',(route->>'epoch')::bigint,o.source_marker,o.remote_user,
            (original->>'user')::uuid,(original->>'account')::uuid,(original->>'creation')::uuid);
    IF m.source_marker IS NULL THEN RETURN; END IF;
    BEGIN
        actual:=meton_ledger.notification_origin(m.environment,m.source,m.epoch,o.channel,o.cash_environment,o.merchant_id,o.app_id,facts);
    EXCEPTION WHEN no_data_found OR invalid_parameter_value THEN RETURN;
    END;
    IF (actual-bound) IS DISTINCT FROM original THEN RETURN; END IF;
    SELECT * INTO p FROM meton_ledger.cash_payments WHERE
        (native_order,source_marker,channel,cash_environment,merchant_id,channel_transaction,order_fen,payer_fen)=
        (o.native_order,m.source_marker,o.channel,o.cash_environment,o.merchant_id,facts->>'transaction',
            (facts->>'total')::bigint,(facts->>'payerTotal')::bigint);
    IF p.payment_id IS NULL OR EXISTS(SELECT FROM meton_ledger.cash_payment_conflicts WHERE payment_id=p.payment_id) THEN RETURN; END IF;
    IF link->>'noticeKind' IN ('payment','payment_query') THEN
        IF facts->>'kind'='payment' AND facts->>'state'='SUCCESS' AND
            (p.currency,p.payer_currency,p.paid_at)=(facts->>'currency',facts->>'payerCurrency',(facts->>'occurredAt')::timestamptz) THEN
            RETURN QUERY SELECT m.source_marker,'payment/'||p.payment_id::text;
        END IF;
        RETURN;
    END IF;
    SELECT * INTO r FROM meton_ledger.cash_refunds WHERE (out_refund_no,native_order,requested_fen)=
        (facts->>'refundOrder',o.native_order,(facts->>'refundFen')::bigint);
    IF r.refund_id IS NULL OR facts->>'kind' IS DISTINCT FROM 'refund' OR
        NOT EXISTS(SELECT FROM meton_ledger.cash_parts part WHERE (part.part_id,part.payment_id,part.source_marker)=(r.part_id,p.payment_id,m.source_marker)) OR
        meton_ledger.refund_payment_disputed(m.source_marker,o.native_order,p.payment_id,r.legacy_cutoff) THEN RETURN; END IF;
    IF r.phase='settled' THEN
        observed:=(o.native_order,m.source_marker,o.channel,o.cash_environment,o.merchant_id,p.channel_transaction,
            sha256(convert_to((facts-'delivery')::text,'UTF8')),facts-'delivery')::meton_ledger.cash_refund_observations;
        -- 复用原退款的结清核对；另一笔、矛盾结果或不同经济事实不能借当前终态消除原通知待办。
        IF NOT meton_ledger.refund_observation_settled(observed) THEN RETURN; END IF;
    ELSIF r.phase='released' AND facts->>'state' NOT IN ('CLOSED','ABNORMAL') THEN RETURN;
    END IF;
    RETURN QUERY SELECT m.source_marker,'refund/'||r.refund_id::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.cash_notice_original(jsonb,jsonb) FROM PUBLIC;

DO $notice_original$
DECLARE body text:=pg_get_functiondef('meton_ledger.read_cash_archive_original(jsonb,jsonb)'::regprocedure);
    point text:='ELSIF link->>''kind''=''refund'' AND item#>>''{value,kind}'' IN (''refund'',''alternative'') THEN';
    declarations text:='owner jsonb; source_key text;';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 OR cardinality(string_to_array(body,declarations))<>2 THEN
        RAISE EXCEPTION 'source archive reader changed'; END IF;
    body:=replace(body,declarations,'owner jsonb; notice_marker uuid; source_key text;');
    EXECUTE replace(body,point,$branch$
    ELSIF link->>'kind'='notice' AND item#>>'{value,kind}'='proof' AND item#>>'{value,noticeKind}'=link->>'noticeKind' THEN
        SELECT v.marker,v.original_key INTO notice_marker,source_key FROM meton_ledger.cash_notice_original(route,link) v;
        SELECT * INTO m FROM public.meton_managed_creations WHERE
            (source_marker,environment,source,epoch)=(notice_marker,a.deployment,a.source,a.epoch);
        IF m.source_marker IS NULL THEN source_key:=NULL; END IF;
    $branch$||point);
END $notice_original$;
