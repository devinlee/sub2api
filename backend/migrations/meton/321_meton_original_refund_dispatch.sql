-- 出站前冻结原退款、原商户、原付款身份和时间窗口。占用及资金结清仍由原退款事务处理。
CREATE TABLE meton_ledger.refund_dispatch_policies(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,channel text NOT NULL CHECK(channel='wechatpay'),
    cash_environment text NOT NULL CHECK(cash_environment='isolated'),merchant text NOT NULL,app text NOT NULL,
    send_seconds integer NOT NULL CHECK(send_seconds BETWEEN 60 AND 31536000),
    query_seconds integer NOT NULL CHECK(query_seconds BETWEEN send_seconds AND 31536000),
    PRIMARY KEY(deployment,source,epoch,channel,cash_environment,merchant,app)
);
CREATE TABLE meton_ledger.refund_dispatch_bases(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.cash_refunds,marker uuid NOT NULL,scope jsonb NOT NULL,envelope jsonb NOT NULL,
    send_until timestamptz NOT NULL,query_until timestamptz NOT NULL CHECK(send_until<=query_until)
);
CREATE TABLE meton_ledger.refund_dispatch_schedule(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.cash_refunds,token uuid NOT NULL,generation bigint NOT NULL,next_at timestamptz NOT NULL,
    state text NOT NULL CHECK(state IN ('working','unknown','pending','evidence','review')), reason text NOT NULL,
    attempts bigint NOT NULL DEFAULT 1 CHECK(attempts>0)
);
CREATE INDEX original_refund_due ON meton_ledger.refund_dispatch_schedule(next_at,refund);
CREATE TABLE meton_ledger.refund_dispatch_marks(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_dispatch_bases,ticket uuid NOT NULL UNIQUE,origin_hash bytea NOT NULL CHECK(octet_length(origin_hash)=32),
    marked_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
DO $guards$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['refund_dispatch_policies','refund_dispatch_bases','refund_dispatch_marks'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',n);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
    END LOOP;
END $guards$;
REVOKE ALL ON meton_ledger.refund_dispatch_policies,meton_ledger.refund_dispatch_bases,meton_ledger.refund_dispatch_schedule,meton_ledger.refund_dispatch_marks FROM PUBLIC;

-- 老程序使用已验微信支付通知里的 amount.total 记录 ORDER_PAID，没有记录 payer_total 就保留缺失。
CREATE FUNCTION meton_ledger.original_refund_payment(owner jsonb,r meton_ledger.cash_refunds,route jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE wire jsonb; history jsonb; f jsonb; n public.payment_orders; paid numeric; paid_at timestamptz; rc meton_ledger.legacy_refund_routes;
BEGIN
    IF r.part_id IS NOT NULL THEN
        SELECT jsonb_build_object('merchant',o.merchant_id,'app',o.app_id,'order',o.out_trade_no,'transaction',p.channel_transaction,
            'refundOrder',r.out_refund_no,'total',p.order_fen,'payerTotal',p.payer_fen,'refundFen',r.requested_fen,'paidAt',p.paid_at)
        INTO wire FROM meton_ledger.cash_parts b JOIN meton_ledger.cash_payments p USING(payment_id,native_order,source_marker)
            JOIN meton_ledger.cash_orders o USING(native_order,source_marker)
        WHERE (b.part_id,o.native_order,o.source_marker,b.basis)=(r.part_id,r.native_order,(owner->>'source_marker')::uuid,r.basis)
            AND (o.channel,o.cash_environment,o.merchant_id,o.app_id)=(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
            AND p.currency='CNY' AND p.payer_currency='CNY' AND r.requested_fen<=b.basis_fen AND r.requested_fen<=p.order_fen
            AND NOT EXISTS(SELECT FROM meton_ledger.cash_payment_conflicts k WHERE k.payment_id=p.payment_id OR
                (k.claimed_intent,k.claimed_marker)=(o.intent_id,o.source_marker));
        RETURN wire;
    END IF;
    history:=meton_ledger.read_legacy_cash_order(owner,r.legacy_cutoff,r.native_order);
    IF (history->>'basis'=r.basis AND history->>'state' IN ('paid_unfulfilled','source_opened') AND history->>'currency'='CNY'
        AND (history->>'hasOrderReferences')::boolean AND history->>'verifiedPayAmount' IS NOT NULL) IS NOT TRUE THEN RETURN NULL; END IF;
    SELECT proof INTO f FROM meton_ledger.legacy_cash_facts WHERE (cutoff,kind,native_id)=(r.legacy_cutoff,'order',r.native_order);
    SELECT * INTO rc FROM meton_ledger.legacy_refund_routes WHERE (deployment,source,provider_instance,channel,cash_environment,merchant,app)=
        (owner->>'environment',owner->>'source',f->>'provider_instance',route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app');
    SELECT * INTO n FROM public.payment_orders WHERE (id,user_id)=(r.native_order,(owner->>'remote_user')::bigint);
    paid:=(history->>'verifiedPayAmount')::numeric*100;paid_at:=(history->>'paidAt')::timestamptz;
    IF rc.provider_instance IS NULL OR f->>'provider_key' IS DISTINCT FROM 'wxpay' OR n.id IS NULL OR paid_at IS NULL OR
        paid IS NULL OR paid<>trunc(paid) OR paid<r.requested_fen OR paid>9223372036854775807 OR
        (meton_ledger.legacy_hash(n.out_trade_no),meton_ledger.legacy_hash(n.payment_trade_no)) IS DISTINCT FROM (f->>'merchant_ref',f->>'trade_ref') THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('merchant',rc.merchant,'app',rc.app,'order',n.out_trade_no,'transaction',n.payment_trade_no,'refundOrder',r.out_refund_no,
        'total',paid::bigint,'payerTotalUnrecorded',true,'refundFen',r.requested_fen,'paidAt',paid_at);
END $$;

CREATE FUNCTION meton_ledger.claim_original_refund_work(route jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE p meton_ledger.refund_dispatch_policies; r meton_ledger.cash_refunds; d meton_ledger.cash_refund_decisions; g meton_ledger.refund_gate_origins;
    m public.meton_managed_creations; a meton_ledger.refund_gate_authorities; b meton_ledger.refund_dispatch_bases;
    owner jsonb; wire jsonb; envelope jsonb; material jsonb; stable jsonb; lease_id uuid:=gen_random_uuid();
    until_send timestamptz; until_query timestamptz; mode text; why text; deadline timestamptz;
BEGIN
    PERFORM meton_ledger.require_cash_writer(route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    SELECT * INTO p FROM meton_ledger.refund_dispatch_policies WHERE (deployment,source,epoch,channel,cash_environment,merchant,app)=
        (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') FOR SHARE;
    SELECT * INTO a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=(p.deployment,p.source,p.epoch) FOR SHARE;
    IF p.deployment IS NULL OR a.key_ref IS NULL OR (route->>'sourceSystem',route->>'inboxSystem') IS DISTINCT FROM
        (meton_ledger.notification_system_id(),a.inbox_system) OR route->>'sourceSystem'=a.inbox_system THEN
        RAISE EXCEPTION 'current refund dispatch route required' USING ERRCODE='42501'; END IF;
    SELECT x.* INTO r FROM meton_ledger.cash_refunds x JOIN meton_ledger.cash_refund_decisions dec USING(refund_id)
        JOIN public.meton_managed_creations cm ON cm.source_marker=dec.source_marker
        JOIN meton_ledger.cash_refund_quotes q ON q.quote_id=dec.quote_id
        LEFT JOIN meton_ledger.refund_dispatch_schedule sched ON sched.refund=x.refund_id
        LEFT JOIN meton_ledger.cash_orders ord ON ord.native_order=x.native_order AND ord.source_marker=dec.source_marker
        LEFT JOIN meton_ledger.legacy_cash_facts hist ON (hist.cutoff,hist.kind,hist.native_id)=(x.legacy_cutoff,'order',x.native_order)
        LEFT JOIN meton_ledger.legacy_refund_routes cfg ON (cfg.deployment,cfg.source,cfg.provider_instance)=(cm.environment,cm.source,hist.proof->>'provider_instance')
        WHERE x.phase IN ('held','possibly_sent','unknown') AND q.generation=p.epoch AND (cm.environment,cm.source,cm.epoch)=(p.deployment,p.source,p.epoch)
            AND (COALESCE(ord.channel,cfg.channel),COALESCE(ord.cash_environment,cfg.cash_environment),COALESCE(ord.merchant_id,cfg.merchant),
                COALESCE(ord.app_id,cfg.app))=(p.channel,p.cash_environment,p.merchant,p.app)
            AND (sched.refund IS NULL OR sched.state NOT IN ('review','evidence') AND sched.next_at<=clock_timestamp())
        ORDER BY COALESCE(sched.next_at,dec.recorded_at),x.refund_id LIMIT 1 FOR UPDATE OF x SKIP LOCKED;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO STRICT d FROM meton_ledger.cash_refund_decisions WHERE refund_id=r.refund_id;
    SELECT * INTO STRICT m FROM public.meton_managed_creations WHERE source_marker=d.source_marker;
    owner:=jsonb_build_object('environment',p.deployment,'source',p.source,'epoch',p.epoch,'user',m.meton_user,'account',m.account,
        'creation',m.operation,'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker,'source_system',route->>'sourceSystem');
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE refund=r.refund_id;
    stable:=jsonb_build_object('deployment',p.deployment,'source',p.source,'epoch',p.epoch,'channel',p.channel,'cashEnvironment',p.cash_environment,
        'merchant',p.merchant,'app',p.app,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system,'keyRef',a.key_ref);
    wire:=meton_ledger.original_refund_payment(owner,r,route);
    until_send:=least((wire->>'paidAt')::timestamptz+interval '8760 hours',d.recorded_at+make_interval(secs=>p.send_seconds));
    until_query:=d.recorded_at+make_interval(secs=>p.query_seconds);
    IF (g.marker,g.accepted_epoch,g.source_system,g.inbox_system) IS DISTINCT FROM (m.source_marker,p.epoch,route->>'sourceSystem',a.inbox_system) THEN why:='missing_original_gate';
    ELSIF wire IS NULL OR (wire->>'order'~'^[A-Za-z0-9_|*@-]{1,64}$' AND wire->>'transaction'~'^[A-Za-z0-9_.:-]{1,64}$'
        AND wire->>'refundOrder'='R'||replace(r.refund_id::text,'-','') AND (wire->>'paidAt')::timestamptz<=clock_timestamp()) IS NOT TRUE THEN why:='missing_original_payment';
    ELSIF until_query<=clock_timestamp() THEN why:='query_window_elapsed';
    END IF;
    IF why IS NULL THEN
        envelope:=jsonb_build_object('format',1,'scope',stable,'target',g.target,'cash',wire-'paidAt','paidAt',wire->'paidAt','acceptedAt',d.recorded_at,
            'sendUntil',until_send,'queryUntil',until_query);
        INSERT INTO meton_ledger.refund_dispatch_bases VALUES(r.refund_id,m.source_marker,stable,envelope,until_send,until_query) ON CONFLICT DO NOTHING;
        SELECT * INTO STRICT b FROM meton_ledger.refund_dispatch_bases WHERE refund=r.refund_id;
        IF (b.scope,b.envelope,b.marker) IS DISTINCT FROM (stable,envelope,m.source_marker) THEN why:='original_cash_changed'; END IF;
    END IF;
    INSERT INTO meton_ledger.refund_dispatch_schedule AS sched(refund,token,generation,next_at,state,reason)
        VALUES(r.refund_id,lease_id,p.epoch,clock_timestamp()+interval '15 seconds',CASE WHEN why IS NULL THEN 'working' ELSE 'review' END,coalesce(why,'lookup'))
        ON CONFLICT(refund) DO UPDATE SET token=excluded.token,generation=excluded.generation,next_at=excluded.next_at,state=excluded.state,
            reason=excluded.reason,attempts=sched.attempts+1;
    IF why IS NOT NULL THEN
        UPDATE meton_ledger.cash_refunds SET phase='review',disposition_version=disposition_version+1 WHERE refund_id=r.refund_id;
        RETURN jsonb_build_object('mode','review','reason',why); END IF;
    mode:=CASE WHEN r.phase='held' AND until_send>clock_timestamp() AND NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_marks WHERE refund=r.refund_id)
        AND NOT EXISTS(SELECT FROM meton_ledger.cash_refund_observations x WHERE x.native_order=r.native_order AND x.transaction_id=wire->>'transaction'
            AND x.facts->>'refundOrder'=r.out_refund_no) THEN 'claim' ELSE 'query' END;
    deadline:=least(clock_timestamp()+interval '24 seconds',until_query);
    IF mode='claim' THEN deadline:=least(deadline,until_send); END IF;
    IF deadline<=clock_timestamp() THEN RETURN jsonb_build_object('mode','review','reason','elapsed'); END IF;
    material:=meton_ledger.refund_gate_material(owner,r.intent_id,r.refund_id,'claimed',deadline);
    RETURN jsonb_build_object('mode',mode,'refund',r.refund_id,'intent',r.intent_id,'lease',lease_id,'owner',owner,'material',material,'envelope',b.envelope,
        'wireMac',encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.dispatch.v1',mode,material->'scope',b.envelope)::text,'UTF8'),a.seal_key),'hex'));
END $$;

-- 源库登记不确定性之后才产生一次 I/O 放行凭证。已过期工作者只有读取原号的机会。
CREATE FUNCTION meton_ledger.mark_original_refund_dispatch(owner jsonb,ref uuid,lease_id uuid,receipt jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b meton_ledger.refund_dispatch_bases; result text; ticket_id uuid:=(receipt#>>'{facts,ticket}')::uuid;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    SELECT * INTO b FROM meton_ledger.refund_dispatch_bases WHERE (refund,marker)=(ref,(owner->>'source_marker')::uuid);
    IF b.refund IS NULL OR NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_schedule WHERE (refund,token,generation,state)=
        (ref,lease_id,(owner->>'epoch')::bigint,'working') AND next_at>clock_timestamp() FOR SHARE) THEN RETURN 'stale'; END IF;
    result:=meton_ledger.apply_refund_gate_receipt(owner,(b.envelope#>>'{target,intent}')::uuid,ref,receipt);
    IF result='possibly_sent' AND receipt#>>'{facts,choice}'='claimed' THEN
        INSERT INTO meton_ledger.refund_dispatch_marks(refund,ticket,origin_hash) VALUES(ref,ticket_id,sha256(convert_to(b.envelope::text,'UTF8'))) ON CONFLICT DO NOTHING;
        IF NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_marks WHERE (refund,ticket,origin_hash)=(ref,ticket_id,sha256(convert_to(b.envelope::text,'UTF8')))) THEN
            RAISE EXCEPTION 'original refund dispatch mark conflict' USING ERRCODE='23505'; END IF;
    END IF;
    RETURN result;
END $$;
CREATE FUNCTION meton_ledger.original_refund_io_permit(owner jsonb,ref uuid,lease_id uuid,gate_scope jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b meton_ledger.refund_dispatch_bases; k meton_ledger.refund_dispatch_marks; a meton_ledger.refund_gate_authorities;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    SELECT * INTO b FROM meton_ledger.refund_dispatch_bases WHERE (refund,marker)=(ref,(owner->>'source_marker')::uuid);
    SELECT * INTO k FROM meton_ledger.refund_dispatch_marks WHERE refund=ref AND marked_xid<>pg_current_xact_id();
    SELECT * INTO a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=(owner->>'environment',owner->>'source',(owner->>'epoch')::bigint) FOR SHARE;
    IF b.refund IS NULL OR k.ticket IS NULL OR a.key_ref IS NULL OR b.send_until<=clock_timestamp() OR
        gate_scope-'validUntil' IS DISTINCT FROM b.scope-ARRAY['merchant','app','channel','cashEnvironment'] OR
        ((gate_scope->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND least(clock_timestamp()+interval '30 seconds',b.send_until)) IS NOT TRUE OR
        NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_schedule s JOIN meton_ledger.cash_refunds r ON r.refund_id=s.refund
            WHERE (s.refund,s.token,s.generation,s.state,r.phase)=(ref,lease_id,a.epoch,'working','possibly_sent') AND s.next_at>clock_timestamp()) THEN RETURN NULL; END IF;
    RETURN encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.io.v1',gate_scope,b.envelope,k.ticket)::text,'UTF8'),a.seal_key),'hex');
END $$;

CREATE FUNCTION meton_ledger.finish_original_refund_work(owner jsonb,ref uuid,lease_id uuid,outcome text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b meton_ledger.refund_dispatch_bases; next_state text;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    SELECT * INTO b FROM meton_ledger.refund_dispatch_bases WHERE (refund,marker)=(ref,(owner->>'source_marker')::uuid);
    IF b.refund IS NULL OR outcome IS NULL OR outcome NOT IN ('unknown','pending','evidence','review','released') THEN RETURN false; END IF;
    next_state:=CASE WHEN outcome IN ('released','evidence') THEN 'evidence' WHEN b.query_until<=clock_timestamp() THEN 'review' ELSE outcome END;
    UPDATE meton_ledger.refund_dispatch_schedule s SET state=next_state,reason=outcome,next_at=least(b.query_until,clock_timestamp()+
        CASE WHEN attempts<=5 THEN interval '60 seconds' ELSE interval '5 minutes' END)
        WHERE (s.refund,s.token,s.generation,s.state)=(ref,lease_id,(owner->>'epoch')::bigint,'working');
    IF NOT FOUND THEN RETURN false; END IF;
    IF next_state='review' THEN
        UPDATE meton_ledger.cash_refunds SET phase='review',disposition_version=disposition_version+1 WHERE refund_id=ref AND phase IN ('held','possibly_sent','unknown');
    END IF;
    RETURN true;
END $$;
CREATE FUNCTION meton_ledger.refund_dispatch_ready(route jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.refund_dispatch_policies p JOIN meton_ledger.refund_gate_authorities a USING(deployment,source,epoch)
        JOIN public.meton_managed_fence f USING(source,epoch) WHERE f.singleton AND f.enabled AND f.environment=p.deployment
            AND (p.deployment,p.source,p.epoch,p.channel,p.cash_environment,p.merchant,p.app,a.inbox_system)=
                (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',route->>'inboxSystem')
            AND route->>'sourceSystem'=meton_ledger.notification_system_id() AND a.inbox_system<>route->>'sourceSystem')
$$;
REVOKE ALL ON FUNCTION meton_ledger.refund_dispatch_ready(jsonb),meton_ledger.original_refund_payment(jsonb,meton_ledger.cash_refunds,jsonb),meton_ledger.claim_original_refund_work(jsonb),
    meton_ledger.mark_original_refund_dispatch(jsonb,uuid,uuid,jsonb),meton_ledger.original_refund_io_permit(jsonb,uuid,uuid,jsonb),
    meton_ledger.finish_original_refund_work(jsonb,uuid,uuid,text) FROM PUBLIC;
