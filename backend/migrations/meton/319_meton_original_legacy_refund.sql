-- 旧微信退款号属于原商户与旧提供方实例。显式登记原映射，当前支付配置不能代替历史商户。
CREATE TABLE meton_ledger.legacy_refund_routes(
    deployment text NOT NULL,source text NOT NULL,provider_instance text NOT NULL,
    channel text NOT NULL CHECK(channel='wechatpay'),cash_environment text NOT NULL CHECK(cash_environment IN ('isolated','live')),
    merchant text NOT NULL,app text NOT NULL,evidence_ref text NOT NULL CHECK(evidence_ref~'^[0-9a-f]{64}$'),
    PRIMARY KEY(deployment,source,provider_instance)
);
CREATE TRIGGER immutable_legacy_refund_route BEFORE UPDATE OR DELETE ON meton_ledger.legacy_refund_routes
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.legacy_refund_routes ENABLE ALWAYS TRIGGER immutable_legacy_refund_route;
REVOKE ALL ON meton_ledger.legacy_refund_routes FROM PUBLIC;

-- 只从冻结订单及与原摘要一致的原生审计识别扣减。旧接口把异常映射为失败，状态文字不能证明现金结论。
CREATE FUNCTION meton_ledger.original_legacy_refund_debit(o jsonb,original_cut uuid,p_order bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE f jsonb; pending meton_ledger.legacy_cash_facts; rollback meton_ledger.legacy_cash_facts;
    raw text; rollback_raw text; detail jsonb; deduction jsonb; rollback_detail jsonb; route meton_ledger.legacy_refund_routes;
    native public.payment_orders; refund_fen numeric; part numeric; disposition text; amount_text text;
BEGIN
    PERFORM meton_ledger.require_legacy_cash_cutoff(o,original_cut);
    SELECT c.proof INTO f FROM meton_ledger.legacy_cash_handoffs h JOIN meton_ledger.legacy_cash_facts c
        ON (c.cutoff,c.kind,c.native_id)=(h.cutoff,'order',h.native_order)
        WHERE (h.cutoff,h.native_order,h.source_marker)=(original_cut,p_order,(o->>'source_marker')::uuid) AND h.proof_hash=sha256(convert_to(c.proof::text,'UTF8'));
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO native FROM public.payment_orders WHERE (id,user_id)=(p_order,(o->>'remote_user')::bigint);
    SELECT * INTO route FROM meton_ledger.legacy_refund_routes WHERE (deployment,source,provider_instance)=(o->>'environment',o->>'source',f->>'provider_instance');
    IF native.id IS NULL OR route.provider_instance IS NULL OR f->>'provider_key' IS DISTINCT FROM 'wxpay' OR f->>'currency_evidence' IS DISTINCT FROM 'CNY' OR
        f->>'order_type' IS DISTINCT FROM 'balance' OR f->>'paid_at' IS NULL OR f->>'state' NOT IN ('REFUND_PENDING','REFUND_FAILED') OR
        f->>'trade_ref' IS NULL OR f->>'merchant_ref' IS NULL OR (f->>'trade_ref',f->>'merchant_ref') IS DISTINCT FROM
            (meton_ledger.legacy_hash(native.payment_trade_no),meton_ledger.legacy_hash(native.out_trade_no)) THEN RETURN jsonb_build_object('state','review'); END IF;
    IF EXISTS(SELECT FROM meton_ledger.legacy_cash_facts x JOIN meton_ledger.legacy_balance_fences fb USING(cutoff)
        JOIN public.meton_managed_creations m ON m.source_marker=fb.source_marker WHERE x.kind='order' AND (x.cutoff,x.native_id)<>(original_cut,p_order)
        AND (m.environment,m.source,x.proof->>'provider_key',x.proof->>'provider_instance')=(route.deployment,route.source,'wxpay',route.provider_instance)
        AND (x.proof->>'trade_ref'=f->>'trade_ref' OR x.proof->>'merchant_ref'=f->>'merchant_ref')) THEN RETURN jsonb_build_object('state','review'); END IF;
    SELECT x.* INTO pending FROM meton_ledger.legacy_cash_facts x WHERE (x.cutoff,x.kind,x.proof->>'order_id',x.proof->>'action')=
        (original_cut,'order_audit',p_order::text,'REFUND_PENDING');
    SELECT l.detail INTO raw FROM public.payment_audit_logs l WHERE (l.id,l.order_id,l.action)=(pending.native_id,p_order::text,'REFUND_PENDING');
    deduction:=meton_ledger.legacy_pending_deduction(pending.proof->>'detail_digest',raw);
    IF pending.native_id IS NULL OR deduction->>'state' NOT IN ('held','returned') OR deduction->>'refundRef' IS NULL OR
        NOT (deduction->>'deductionType' IS NOT DISTINCT FROM 'balance' OR deduction->>'state'='returned' AND deduction->>'deductionType' IS NULL) OR
        (deduction->>'balanceUnits')::numeric NOT BETWEEN 0.00000001 AND 999999999999.99999999 THEN
        RETURN jsonb_build_object('state','review'); END IF;
    detail:=raw::jsonb;part:=(deduction->>'balanceUnits')::numeric;refund_fen:=(f->>'reported_refund')::numeric*100;
    IF refund_fen IS NULL OR refund_fen<>trunc(refund_fen) OR refund_fen NOT BETWEEN 1 AND 9223372036854775807 OR
        (f->>'order_pay_amount')::numeric*100 IS DISTINCT FROM trunc((f->>'order_pay_amount')::numeric*100) OR
        refund_fen>(f->>'order_pay_amount')::numeric*100 OR (detail?'refundAmount' AND (jsonb_typeof(detail->'refundAmount')<>'number'
            OR (detail->>'refundAmount')::numeric*100 IS DISTINCT FROM refund_fen)) OR f->>'refund_at' IS NOT NULL OR
        EXISTS(SELECT FROM meton_ledger.legacy_cash_facts x WHERE (x.cutoff,x.kind,x.proof->>'order_id')=(original_cut,'order_audit',p_order::text)
            AND x.proof->>'action' LIKE 'REFUND%' AND x.proof->>'action' NOT IN ('REFUND_PENDING','REFUND_REQUESTED','REFUND_FAILED','REFUND_ROLLBACK_FAILED','REFUND_QUERY_PENDING')) THEN
        RETURN jsonb_build_object('state','review'); END IF;
    SELECT x.* INTO rollback FROM meton_ledger.legacy_cash_facts x WHERE (x.cutoff,x.kind,x.proof->>'order_id',x.proof->>'action')=
        (original_cut,'order_audit',p_order::text,'REFUND_ROLLBACK_FAILED');
    IF rollback.native_id IS NOT NULL THEN
        SELECT l.detail INTO rollback_raw FROM public.payment_audit_logs l WHERE (l.id,l.order_id,l.action)=(rollback.native_id,p_order::text,'REFUND_ROLLBACK_FAILED');
        IF meton_ledger.legacy_hash(rollback_raw) IS DISTINCT FROM rollback.proof->>'detail_digest' OR octet_length(rollback_raw)>65536 THEN RETURN jsonb_build_object('state','review'); END IF;
        BEGIN rollback_detail:=rollback_raw::jsonb; EXCEPTION WHEN data_exception THEN RETURN jsonb_build_object('state','review'); END;
        amount_text:=rollback_detail->>'balanceDeducted';
        IF jsonb_typeof(rollback_detail->'rollbackError') IS DISTINCT FROM 'string' OR nullif(trim(rollback_detail->>'rollbackError'),'') IS NULL OR
            jsonb_typeof(rollback_detail->'balanceDeducted') IS DISTINCT FROM 'number' OR amount_text!~'^[0-9]+([.][0-9]{1,8})?$'
            OR amount_text::numeric<>part OR deduction->>'state'='returned' OR (rollback.proof->>'created_at')::timestamptz<(pending.proof->>'created_at')::timestamptz THEN
            RETURN jsonb_build_object('state','review'); END IF;
    END IF;
    disposition:=CASE WHEN deduction->>'state'='returned' THEN 'returned'
        WHEN f->>'state'='REFUND_PENDING' AND rollback.native_id IS NULL AND NOT EXISTS(SELECT FROM meton_ledger.legacy_cash_facts x WHERE
            (x.cutoff,x.kind,x.proof->>'order_id',x.proof->>'action')=(original_cut,'order_audit',p_order::text,'REFUND_FAILED')) THEN 'held'
        WHEN f->>'state'='REFUND_FAILED' AND rollback.native_id IS NOT NULL AND EXISTS(SELECT FROM meton_ledger.legacy_cash_facts x
            WHERE (x.cutoff,x.kind,x.proof->>'order_id',x.proof->>'action')=(original_cut,'order_audit',p_order::text,'REFUND_FAILED')
                AND (x.proof->>'created_at')::timestamptz>=(pending.proof->>'created_at')::timestamptz) THEN 'held'
        ELSE 'review' END;
    IF disposition='review' THEN RETURN jsonb_build_object('state','review'); END IF;
    RETURN jsonb_build_object('state',disposition,'cutoff',original_cut,'marker',o->>'source_marker','user',o->>'user','account',o->>'account','creation',o->>'creation',
        'order',p_order::text,'providerInstance',route.provider_instance,'routeEvidence',route.evidence_ref,'channel',route.channel,'cashEnvironment',route.cash_environment,
        'merchant',route.merchant,'app',route.app,'trade',native.out_trade_no,'transaction',native.payment_trade_no,'refundOrder',deduction->>'refundRef',
        'refundFen',refund_fen::bigint::text,'paidFen',((f->>'order_pay_amount')::numeric*100)::bigint::text,'units',part::numeric(20,8)::text,
        'audit',pending.native_id::text,'auditHash',pending.proof->>'detail_digest','rollbackHash',rollback.proof->>'detail_digest');
END $$;

CREATE FUNCTION meton_ledger.legacy_refund_review_material(o jsonb,original_cut uuid,p_order bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t jsonb; a meton_ledger.refund_gate_authorities; scope jsonb;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(o);
    t:=meton_ledger.original_legacy_refund_debit(o,original_cut,p_order);
    IF t IS NULL OR t->>'state'='review' THEN RETURN t; END IF;
    SELECT * INTO STRICT a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint) FOR SHARE;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'sourceSystem',meton_ledger.notification_system_id(),
        'inboxSystem',a.inbox_system,'keyRef',a.key_ref);
    IF a.inbox_system=scope->>'sourceSystem' THEN RAISE EXCEPTION 'legacy refund requires independent archive' USING ERRCODE='55000'; END IF;
    RETURN jsonb_build_object('scope',scope,'target',t,'permit',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.legacy.refund.debit.v1',scope,t)::text,'UTF8'),a.seal_key),'hex'));
END $$;

-- 历史退款通知继续由原签名收件与消费程序处理。只接受确切归属的原付款，不创建现代订单或退款。
CREATE FUNCTION meton_ledger.legacy_refund_notice_origin(dep text,src text,gen bigint,ch text,env text,mch text,application text,n jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE candidate record; first_origin jsonb; owner jsonb; debit jsonb;
BEGIN
    IF n->>'kind' IS DISTINCT FROM 'refund' THEN RETURN NULL; END IF;
    FOR candidate IN SELECT h.cutoff,h.native_order,m.* FROM meton_ledger.legacy_cash_handoffs h
        JOIN meton_ledger.legacy_cash_facts f ON (f.cutoff,f.kind,f.native_id)=(h.cutoff,'order',h.native_order)
        JOIN public.meton_managed_creations m ON m.source_marker=h.source_marker
        JOIN meton_ledger.legacy_refund_routes cfg ON (cfg.deployment,cfg.source,cfg.provider_instance)=(m.environment,m.source,f.proof->>'provider_instance')
        WHERE (m.environment,m.source,m.epoch,cfg.channel,cfg.cash_environment,cfg.merchant,cfg.app)=(dep,src,gen,ch,env,mch,application)
            AND (f.proof->>'provider_key',f.proof->>'merchant_ref',f.proof->>'trade_ref')=('wxpay',meton_ledger.legacy_hash(n->>'order'),meton_ledger.legacy_hash(n->>'transaction'))
    LOOP
        IF first_origin IS NOT NULL THEN RAISE EXCEPTION 'historical cash identity conflicts' USING ERRCODE='22023'; END IF;
        owner:=jsonb_build_object('environment',dep,'source',src,'epoch',gen,'user',candidate.meton_user,'account',candidate.account,
            'creation',candidate.operation,'dispatch',candidate.dispatch,'remote_user',candidate.remote_user,'source_marker',candidate.source_marker,'source_system',meton_ledger.notification_system_id());
        debit:=meton_ledger.original_legacy_refund_debit(owner,candidate.cutoff,candidate.native_order);
        IF debit IS NULL OR debit->>'state' NOT IN ('held','returned') THEN RAISE EXCEPTION 'historical cash requires original proof' USING ERRCODE='P0002'; END IF;
        IF (n->>'merchant', (n->>'total')::bigint) IS DISTINCT FROM (mch, (debit->>'paidFen')::bigint) THEN
            RAISE EXCEPTION 'historical refund differs from original payment' USING ERRCODE='22023'; END IF;
        first_origin:=jsonb_build_object('version',1,'legacyCutoff',candidate.cutoff,'legacyOrder',candidate.native_order::text,'legacyAudit',debit->>'auditHash',
            'sourceMarker',candidate.source_marker,'user',candidate.meton_user,'account',candidate.account,'creation',candidate.operation,'order',n->>'order',
            'channel',ch,'cashEnvironment',env,'merchant',mch,'app',application,'currency','CNY','priceFen',debit->>'paidFen','providerInstance',debit->>'providerInstance');
    END LOOP;
    RETURN first_origin;
END $$;
DO $origin$
DECLARE src text:=pg_get_functiondef('meton_ledger.notification_origin(text,text,bigint,text,text,text,text,jsonb)'::regprocedure);
    point constant text:='IF NOT FOUND THEN RAISE EXCEPTION ''original order unavailable'' USING ERRCODE=''P0002''; END IF;';
BEGIN
    IF cardinality(string_to_array(src,point))<>2 THEN RAISE EXCEPTION 'original notification lookup changed'; END IF;
    EXECUTE replace(src,point,$legacy$IF NOT FOUND THEN
        result:=meton_ledger.legacy_refund_notice_origin(deployment,source_name,generation,channel_id,cash_env,merchant,application,facts);
        IF result IS NOT NULL THEN RETURN result; END IF;
        RAISE EXCEPTION 'original order unavailable' USING ERRCODE='P0002';
    ELSIF facts->>'kind'='refund' AND meton_ledger.legacy_refund_notice_origin(deployment,source_name,generation,channel_id,cash_env,merchant,application,facts) IS NOT NULL THEN
        RAISE EXCEPTION 'current and historical merchant orders conflict' USING ERRCODE='22023'; END IF;$legacy$);
END $origin$;
REVOKE ALL ON FUNCTION meton_ledger.original_legacy_refund_debit(jsonb,uuid,bigint),meton_ledger.legacy_refund_review_material(jsonb,uuid,bigint),
    meton_ledger.legacy_refund_notice_origin(text,text,bigint,text,text,text,text,jsonb) FROM PUBLIC;
