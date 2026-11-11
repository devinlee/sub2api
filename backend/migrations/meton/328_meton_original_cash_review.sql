-- 没有退款记录的付款也会被渠道强制返还。复用原核对事实和权威，不为关联账号制造退款单。
ALTER TABLE meton_ledger.cash_return_reviews DROP CONSTRAINT cash_return_reviews_pkey;
ALTER TABLE meton_ledger.cash_return_reviews ALTER COLUMN refund DROP NOT NULL;
ALTER TABLE meton_ledger.cash_return_reviews
    ADD CONSTRAINT cash_return_review_identity UNIQUE NULLS NOT DISTINCT(refund,evidence),
    ADD COLUMN original_order bigint REFERENCES public.payment_orders(id),
    ADD COLUMN legacy_credit uuid REFERENCES meton_ledger.lots(credit_event),
    ADD CHECK(refund IS NOT NULL OR original_order IS NOT NULL),
    ADD CHECK(legacy_credit IS NULL OR cutoff IS NOT NULL);

/** 退款结清和原付款核对共用当前权限。重建账号不继承旧工作者的写权。 */
CREATE FUNCTION meton_ledger.require_cash_review_resolver(route jsonb) RETURNS meton_ledger.refund_gate_authorities
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.refund_gate_authorities;
BEGIN
    SELECT ga.* INTO a FROM meton_ledger.refund_gate_authorities ga JOIN meton_ledger.refund_settlement_roles w USING(deployment,source,epoch,key_ref)
        JOIN meton_ledger.refund_dispatch_policies p USING(deployment,source,epoch) JOIN public.meton_managed_fence n ON
            (n.environment,n.source,n.epoch)=(ga.deployment,ga.source,ga.epoch) AND n.singleton AND n.enabled
        WHERE (ga.deployment,ga.source,ga.epoch,w.resolver,ga.inbox_system,p.channel,p.cash_environment,p.merchant,p.app)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,session_user,route->>'inboxSystem',route->>'channel',route->>'cashEnvironment',
             route->>'merchant',route->>'app') AND NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_workers dw WHERE
            (dw.deployment,dw.source,dw.worker_role)=(ga.deployment,ga.source,session_user)) FOR SHARE OF ga,w,p,n;
    IF a.key_ref IS NULL OR route->>'sourceSystem' IS DISTINCT FROM meton_ledger.notification_system_id()
        OR route->>'sourceSystem'=a.inbox_system THEN RAISE EXCEPTION 'current cash review authority required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_cash_writer(a.deployment,a.source,a.epoch);
    RETURN a;
END $$;

/** 原付款人只能由原订单、实付或已接收的历史截点定位，来访材料不能选择账号。 */
CREATE FUNCTION meton_ledger.original_cash_review_origin(route jsonb,trade text,txn text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    m public.meton_managed_creations; p meton_ledger.cash_payments; o meton_ledger.cash_orders;
    h meton_ledger.legacy_cash_handoffs; n public.payment_orders; old_epoch bigint; f jsonb; owner jsonb; cash jsonb;
    credit uuid; total numeric; scope jsonb; marker uuid; order_id bigint;
BEGIN
    IF (length(trade) BETWEEN 1 AND 64 AND length(txn) BETWEEN 1 AND 64) IS NOT TRUE THEN
        RAISE EXCEPTION 'original cash identity required' USING ERRCODE='22023'; END IF;
    SELECT pay.* INTO p FROM meton_ledger.cash_payments pay JOIN meton_ledger.cash_orders ord USING(native_order,source_marker)
        WHERE (ord.channel,ord.cash_environment,ord.merchant_id,ord.app_id,ord.out_trade_no,pay.channel_transaction)=
            (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',trade,txn);
    IF p.payment_id IS NOT NULL THEN
        marker:=p.source_marker;order_id:=p.native_order;
    ELSE
        SELECT hand.* INTO h FROM meton_ledger.legacy_cash_handoffs hand JOIN meton_ledger.legacy_cash_facts v
            ON (v.cutoff,v.kind,v.native_id)=(hand.cutoff,'order',hand.native_order)
            JOIN public.payment_orders native ON (native.id,native.out_trade_no,native.payment_trade_no)=(hand.native_order,trade,txn)
            JOIN public.meton_managed_creations c ON (c.source_marker,c.remote_user)=(hand.source_marker,native.user_id)
            JOIN meton_ledger.legacy_refund_routes cfg ON (cfg.deployment,cfg.source,cfg.provider_instance)=
                (c.environment,c.source,v.proof->>'provider_instance')
            WHERE (cfg.channel,cfg.cash_environment,cfg.merchant,cfg.app)=(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
                AND v.proof->>'provider_key'='wxpay' AND v.proof->>'currency_evidence'='CNY'
                AND (v.proof->>'merchant_ref',v.proof->>'trade_ref')=(meton_ledger.legacy_hash(trade),meton_ledger.legacy_hash(txn));
        IF h.cutoff IS NULL THEN RETURN NULL; END IF;
        marker:=h.source_marker;order_id:=h.native_order;
    END IF;
    SELECT * INTO m FROM public.meton_managed_creations WHERE (source_marker,environment,source,epoch)=(marker,a.deployment,a.source,a.epoch);
    IF m.source_marker IS NULL THEN RETURN NULL; END IF;
    owner:=jsonb_build_object('environment',m.environment,'source',m.source,'epoch',m.epoch,'user',m.meton_user,'account',m.account,
        'creation',m.operation,'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker,'source_system',route->>'sourceSystem');
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(marker));
    -- 跟退款确认同序：原单、原实付、账号。模型预占在同一个账号行锁后重新选择来源。
    IF p.payment_id IS NOT NULL THEN
        SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE (native_order,source_marker)=(order_id,marker) FOR UPDATE;
        PERFORM FROM meton_ledger.cash_payment_dispositions WHERE payment_id=p.payment_id FOR UPDATE;
        cash:=jsonb_build_object('merchant',o.merchant_id,'app',o.app_id,'order',o.out_trade_no,'transaction',p.channel_transaction,
            'total',p.order_fen,'payerTotal',p.payer_fen,'paidAt',p.paid_at);
    ELSE
        PERFORM FROM meton_ledger.legacy_cash_handoffs WHERE (cutoff,native_order,source_marker)=(h.cutoff,order_id,marker) FOR UPDATE;
        SELECT proof INTO STRICT f FROM meton_ledger.legacy_cash_facts WHERE (cutoff,kind,native_id)=(h.cutoff,'order',order_id);
        SELECT * INTO STRICT n FROM public.payment_orders WHERE (id,user_id,out_trade_no,payment_trade_no)=(order_id,m.remote_user,trade,txn);
        SELECT cut_epoch INTO STRICT old_epoch FROM meton_ledger.legacy_balance_fences WHERE cutoff=h.cutoff;
        total:=(f->>'order_pay_amount')::numeric*100;
        IF h.proof_hash<>sha256(convert_to(f::text,'UTF8')) OR NOT meton_ledger.refund_owner_succeeded(m,old_epoch)
            OR (total>0 AND total=trunc(total) AND total<=9223372036854775807 AND n.paid_at=(f->>'paid_at')::timestamptz) IS NOT TRUE THEN RETURN NULL; END IF;
        SELECT e.event_id INTO credit FROM meton_ledger.legacy_source_openings opening
            JOIN meton_ledger.legacy_source_components c ON c.review=opening.review
            JOIN meton_ledger.legacy_opening_events e ON (e.cutoff,e.review,e.ordinal)=(opening.cutoff,opening.review,c.ordinal)
            WHERE (opening.cutoff,opening.source_marker,c.native_kind,c.native_id,c.kind)=(h.cutoff,marker,'order',order_id,'purchase');
        cash:=jsonb_build_object('merchant',route->>'merchant','app',route->>'app','order',trade,'transaction',txn,
            'total',total::bigint,'payerTotalUnrecorded',true,'paidAt',n.paid_at);
    END IF;
    PERFORM FROM public.users u JOIN public.meton_managed_creations current_owner ON current_owner.remote_user=u.id
        WHERE (current_owner.source_marker,current_owner.remote_user,current_owner.epoch)=(marker,m.remote_user,a.epoch)
        FOR SHARE OF current_owner FOR UPDATE OF u;
    IF NOT FOUND THEN RETURN NULL; END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system,'channel',route->>'channel',
        'cashEnvironment',route->>'cashEnvironment','merchant',route->>'merchant','app',route->>'app');
    RETURN jsonb_build_object('scope',scope,'owner',owner,'target',jsonb_build_object('payment',p.payment_id,'cutoff',h.cutoff,
        'nativeOrder',order_id,'legacyCredit',credit),'cash',cash);
END $$;

-- 提取已验过的原金额核对算法，两个入口共用，避免独立定义另一套现金合计或未知上限规则。
DO $validation$
DECLARE body text:=pg_get_functiondef('meton_ledger.capture_external_cash_review(meton_ledger.refund_gate_origins,meton_ledger.cash_refunds,uuid,bigint,jsonb)'::regprocedure);
    first_at integer;last_at integer;checks text;
BEGIN
    first_at:=strpos(body,'    hash:=sha256(convert_to(x::text,');
    last_at:=strpos(body,'    INSERT INTO meton_ledger.cash_return_reviews');
    IF first_at=0 OR last_at<=first_at THEN RAISE EXCEPTION 'original cash exposure checks changed'; END IF;
    checks:=substr(body,first_at,last_at-first_at);
    EXECUTE 'CREATE FUNCTION meton_ledger.checked_cash_exposure(e jsonb,facts jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS '
        ||quote_literal('DECLARE x jsonb:=facts->''cashExposure''; k jsonb:=e->''cash'';s jsonb:=e->''scope'';hash bytea;original bytea;total numeric;cap numeric;
        BEGIN IF x IS NULL THEN RAISE EXCEPTION ''cash exposure required'' USING ERRCODE=''42501''; END IF; '
        ||checks||' RETURN x; END');
    EXECUTE replace(body,checks,'    x:=meton_ledger.checked_cash_exposure(e,facts); hash:=sha256(convert_to(x::text,''UTF8''));'||chr(10));
END $validation$;

/** 当前归档签章只证明原现金事实。此入口追加核对，不修改余额、赠送或退款占用。 */
CREATE FUNCTION meton_ledger.record_original_cash_review(route jsonb,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    facts jsonb:=proof->'facts';e jsonb:=facts->'envelope';actual jsonb;scope jsonb;exposure jsonb;digest bytea;owner_marker uuid;
BEGIN
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF proof->>'state' IS DISTINCT FROM 'review' OR coalesce(octet_length(proof::text),0)>32768
        OR facts->'scope' IS DISTINCT FROM scope OR facts->'format' IS DISTINCT FROM '1'::jsonb
        OR ((facts->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE
        OR proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(
            jsonb_build_array('meton.cash.original.review.v1',facts)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'current original cash proof required' USING ERRCODE='42501'; END IF;
    actual:=meton_ledger.original_cash_review_origin(route,e#>>'{cash,order}',e#>>'{cash,transaction}');
    IF actual IS NULL THEN RETURN 'original_unavailable'; END IF;
    IF actual IS DISTINCT FROM e THEN RAISE EXCEPTION 'original cash review ownership differs' USING ERRCODE='42501'; END IF;
    exposure:=meton_ledger.checked_cash_exposure(e,facts);digest:=sha256(convert_to(exposure::text,'UTF8'));
    owner_marker:=(e#>>'{owner,source_marker}')::uuid;
    INSERT INTO meton_ledger.cash_return_reviews(refund,evidence,marker,payment,cutoff,epoch,snapshot,original_order,legacy_credit)
        VALUES(NULL,digest,owner_marker,(e#>>'{target,payment}')::uuid,(e#>>'{target,cutoff}')::uuid,a.epoch,exposure,
            (e#>>'{target,nativeOrder}')::bigint,(e#>>'{target,legacyCredit}')::uuid) ON CONFLICT DO NOTHING;
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_return_reviews v WHERE v.refund IS NULL AND v.evidence=digest AND
        (v.marker,v.payment,v.cutoff,v.snapshot,v.original_order,v.legacy_credit) IS NOT DISTINCT FROM
        (owner_marker,(e#>>'{target,payment}')::uuid,(e#>>'{target,cutoff}')::uuid,exposure,(e#>>'{target,nativeOrder}')::bigint,(e#>>'{target,legacyCredit}')::uuid)) THEN
        RAISE EXCEPTION 'original review already belongs elsewhere' USING ERRCODE='23505'; END IF;
    RETURN 'review';
END $$;

DO $guards$
DECLARE body text;
BEGIN
    body:=pg_get_functiondef('meton_ledger.refund_payment_disputed(uuid,bigint,uuid,uuid)'::regprocedure);
    IF cardinality(string_to_array(body,'SELECT EXISTS('))<>2 THEN RAISE EXCEPTION 'original dispute predicate changed'; END IF;
    EXECUTE replace(body,'SELECT EXISTS(','SELECT EXISTS(SELECT FROM meton_ledger.cash_return_reviews v WHERE v.refund IS NULL AND
        (v.marker,v.original_order)=($1,$2) AND (v.payment=$3 OR v.cutoff=$4)) OR EXISTS(');
    body:=pg_get_functiondef('meton_ledger.cash_purchase_needs_review(uuid)'::regprocedure);
    IF cardinality(string_to_array(body,'SELECT EXISTS('))<>2 THEN RAISE EXCEPTION 'original credit restriction changed'; END IF;
    EXECUTE replace(body,'SELECT EXISTS(','SELECT EXISTS(SELECT FROM meton_ledger.cash_return_reviews v WHERE v.legacy_credit=$1) OR EXISTS(');
END $guards$;
REVOKE ALL ON FUNCTION meton_ledger.require_cash_review_resolver(jsonb),meton_ledger.original_cash_review_origin(jsonb,text,text),
    meton_ledger.checked_cash_exposure(jsonb,jsonb),meton_ledger.record_original_cash_review(jsonb,jsonb) FROM PUBLIC;
