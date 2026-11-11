-- 通知独立于登录。收件角色只能核实原生订单／退款归属，不能改变其处置或额度。
CREATE FUNCTION meton_ledger.notification_origin(deployment text, source_name text, generation bigint,
    channel_id text, cash_env text, merchant text, application text, facts jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    o meton_ledger.cash_orders%ROWTYPE;
    c public.meton_managed_creations%ROWTYPE;
    r meton_ledger.cash_refunds%ROWTYPE;
    p meton_ledger.cash_payments%ROWTYPE;
    result jsonb;
BEGIN
    IF NOT EXISTS(SELECT FROM public.meton_managed_fence WHERE singleton AND
        (environment,source,epoch)=(deployment,source_name,generation)) THEN
        RAISE EXCEPTION 'notification source unavailable' USING ERRCODE='55000';
    END IF;
    SELECT * INTO o FROM meton_ledger.cash_orders WHERE
        (channel,cash_environment,merchant_id,app_id,out_trade_no)=(channel_id,cash_env,merchant,application,facts->>'order');
    IF NOT FOUND THEN RAISE EXCEPTION 'original order unavailable' USING ERRCODE='P0002'; END IF;
    IF facts->>'merchant' IS DISTINCT FROM merchant
        OR o.price_fen IS DISTINCT FROM (facts->>'total')::bigint THEN
        RAISE EXCEPTION 'original order differs' USING ERRCODE='22023';
    END IF;
    SELECT * INTO STRICT c FROM public.meton_managed_creations WHERE
        (source_marker,remote_user,environment,source)=(o.source_marker,o.remote_user,deployment,source_name);
    -- 用稳定的原账号、意图和价格证明恢复归属。数据库自增号不承担跨快照身份。
    result:=jsonb_build_object('version',1,'account',c.account,'user',c.meton_user,'creation',c.operation,
        'sourceMarker',o.source_marker,'intent',o.intent_id,'order',o.out_trade_no,'paramsHash',o.params_hash,
        'channel',o.channel,'cashEnvironment',o.cash_environment,'merchant',o.merchant_id,'app',o.app_id,
        'currency',o.currency,'priceFen',o.price_fen,'priceVersion',o.price_version,
        'creditUnits',o.credit_units::text,'unit',o.unit,'unitsPerYuan',o.units_per_yuan::text);
    IF facts->>'kind'='payment' THEN
        IF (facts->>'app',facts->>'currency',facts->>'payerCurrency')
            IS DISTINCT FROM (o.app_id,o.currency,o.currency) THEN
            RAISE EXCEPTION 'original payment differs' USING ERRCODE='22023';
        END IF;
        RETURN result;
    END IF;
    IF facts->>'kind' IS DISTINCT FROM 'refund' THEN
        RAISE EXCEPTION 'unknown notification kind' USING ERRCODE='22023';
    END IF;
    SELECT * INTO r FROM meton_ledger.cash_refunds WHERE out_refund_no=facts->>'refundOrder';
    IF NOT FOUND THEN RAISE EXCEPTION 'original refund unavailable' USING ERRCODE='P0002'; END IF;
    IF r.native_order<>o.native_order OR r.requested_fen IS DISTINCT FROM (facts->>'refundFen')::bigint THEN
        RAISE EXCEPTION 'original refund differs' USING ERRCODE='22023';
    END IF;
    SELECT pay.* INTO p FROM meton_ledger.cash_parts part JOIN meton_ledger.cash_payments pay USING(payment_id)
        WHERE part.part_id=r.part_id AND pay.native_order=o.native_order AND pay.source_marker=o.source_marker;
    IF NOT FOUND OR (p.channel_transaction,p.order_fen,p.payer_fen,p.currency,p.payer_currency) IS DISTINCT FROM
        (facts->>'transaction',o.price_fen,(facts->>'payerTotal')::bigint,o.currency,o.currency) THEN
        RAISE EXCEPTION 'original refund payment differs' USING ERRCODE='22023';
    END IF;
    RETURN result||jsonb_build_object('payment',p.payment_id,'part',r.part_id,'refund',r.refund_id,
        'refundIntent',r.intent_id,'refundOrder',r.out_refund_no,'basis',r.basis,
        'requestedFen',r.requested_fen,'requestedUnits',r.requested_units::text);
END $$;

-- 对比两个实际 PostgreSQL 集群身份，避免把来源数据库的别名误装成截点外收件库。
CREATE FUNCTION meton_ledger.notification_system_id() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT system_identifier::text FROM pg_catalog.pg_control_system()
$$;
REVOKE ALL ON FUNCTION meton_ledger.notification_system_id(),
    meton_ledger.notification_origin(text,text,bigint,text,text,text,text,jsonb) FROM PUBLIC;
