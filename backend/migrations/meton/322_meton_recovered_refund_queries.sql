-- 新受理记下当时的签名版本。换密钥或恢复代次后，只能查已登记的原退款，不能重新取得发送权。
CREATE TABLE meton_ledger.refund_dispatch_issuers(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_gate_origins,epoch bigint NOT NULL,source_system text NOT NULL,inbox_system text NOT NULL,key_ref uuid NOT NULL
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_dispatch_issuers FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_dispatch_issuers ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_dispatch_issuers FROM PUBLIC;
CREATE TABLE meton_ledger.refund_dispatch_workers(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,key_ref uuid NOT NULL,worker_role name NOT NULL,
    PRIMARY KEY(deployment,source,epoch,key_ref),UNIQUE(deployment,source,worker_role)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_dispatch_workers FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_dispatch_workers ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_dispatch_workers FROM PUBLIC;
CREATE FUNCTION meton_ledger.active_refund_dispatch_worker(dep text,src text,generation bigint) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.refund_gate_authorities a JOIN meton_ledger.refund_dispatch_workers w USING(deployment,source,epoch,key_ref)
        WHERE (a.deployment,a.source,a.epoch,w.worker_role)=(dep,src,generation,session_user))
$$;
CREATE FUNCTION meton_ledger.record_refund_dispatch_issuer() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    INSERT INTO meton_ledger.refund_dispatch_issuers
        SELECT NEW.refund,a.epoch,NEW.source_system,NEW.inbox_system,a.key_ref FROM meton_ledger.refund_gate_authorities a JOIN public.meton_managed_creations m
            ON m.source_marker=NEW.marker AND (m.environment,m.source,m.epoch)=(a.deployment,a.source,a.epoch)
            WHERE (a.epoch,a.inbox_system)=(NEW.accepted_epoch,NEW.inbox_system);
    IF NOT FOUND THEN RAISE EXCEPTION 'original refund signing version missing' USING ERRCODE='55000'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER original_dispatch_issuer AFTER INSERT ON meton_ledger.refund_gate_origins FOR EACH ROW EXECUTE FUNCTION meton_ledger.record_refund_dispatch_issuer();
ALTER TABLE meton_ledger.refund_gate_origins ENABLE ALWAYS TRIGGER original_dispatch_issuer;

CREATE FUNCTION meton_ledger.dispatch_issuer_current(ref uuid,route jsonb) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT EXISTS(SELECT FROM meton_ledger.refund_gate_origins WHERE refund=ref) OR EXISTS(
        SELECT FROM meton_ledger.refund_dispatch_issuers i JOIN meton_ledger.refund_gate_authorities a ON (i.epoch,i.inbox_system,i.key_ref)=(a.epoch,a.inbox_system,a.key_ref)
        WHERE i.refund=ref AND (a.deployment,a.source,i.epoch,i.source_system,i.inbox_system)=(route->>'deployment',route->>'source',(route->>'epoch')::bigint,
            route->>'sourceSystem',route->>'inboxSystem'))
$$;
DO $guard$
DECLARE body text; k text; fn text;
BEGIN
    body:=pg_get_functiondef('meton_ledger.claim_original_refund_work(jsonb)'::regprocedure);
    k:='IF p.deployment IS NULL';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original refund work route changed'; END IF;
    body:=replace(body,k,'IF NOT meton_ledger.active_refund_dispatch_worker(p.deployment,p.source,p.epoch) OR p.deployment IS NULL');
    k:='AND q.generation=p.epoch AND';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original dispatch scheduling changed'; END IF;
    EXECUTE replace(body,k,'AND meton_ledger.dispatch_issuer_current(x.refund_id,route) '||k);
    body:=pg_get_functiondef('meton_ledger.finish_original_refund_work(jsonb,uuid,uuid,text)'::regprocedure);
    k:='IF b.refund IS NULL OR outcome IS NULL';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original dispatch finish changed'; END IF;
    EXECUTE replace(body,k,'IF NOT meton_ledger.dispatch_issuer_current(ref,b.scope) THEN RETURN false; END IF; '||k);
    FOREACH fn IN ARRAY ARRAY['meton_ledger.finish_original_refund_work(jsonb,uuid,uuid,text)',
        'meton_ledger.mark_original_refund_dispatch(jsonb,uuid,uuid,jsonb)','meton_ledger.original_refund_io_permit(jsonb,uuid,uuid,jsonb)'] LOOP
        body:=pg_get_functiondef(fn::regprocedure);k:='PERFORM meton_ledger.require_refund_gate_writer(owner);';
        IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original refund writer changed'; END IF;
        EXECUTE replace(body,k,k||' IF NOT meton_ledger.active_refund_dispatch_worker(owner->>''environment'',owner->>''source'',(owner->>''epoch'')::bigint)
            THEN RAISE EXCEPTION ''refund writer retired'' USING ERRCODE=''42501''; END IF;');
    END LOOP;
    body:=pg_get_functiondef('meton_ledger.refund_dispatch_ready(jsonb)'::regprocedure);
    k:='WHERE f.singleton AND';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original source readiness changed'; END IF;
    EXECUTE replace(body,k,'WHERE meton_ledger.active_refund_dispatch_worker(p.deployment,p.source,p.epoch) AND f.singleton AND');
    body:=pg_get_functiondef('meton_ledger.refund_gate_material(jsonb,uuid,uuid,text,timestamptz)'::regprocedure);
    k:='RETURN jsonb_build_object(''scope'',scope';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original refund authority changed'; END IF;
    EXECUTE replace(body,k,'IF want=''claimed'' AND (NOT meton_ledger.active_refund_dispatch_worker(a.deployment,a.source,a.epoch)
        OR NOT meton_ledger.dispatch_issuer_current(ref,scope)) THEN
        RAISE EXCEPTION ''original refund is query only'' USING ERRCODE=''42501''; END IF; '||k);
END $guard$;

-- 使用 S1 已提交的原账号接续链。只读核对不会更改来源账号、模型凭据、发送者或资金占用。
CREATE FUNCTION meton_ledger.refund_owner_succeeded(m public.meton_managed_creations,original_epoch bigint) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    WITH RECURSIVE chain(gen) AS (
        SELECT original_epoch WHERE original_epoch>0 AND original_epoch<=m.epoch
        UNION ALL SELECT s.next_epoch FROM chain c JOIN public.meton_recovery_successions s ON c.gen=s.previous_epoch
            AND (s.environment,s.source,s.meton_user,s.account,s.operation,s.dispatch,s.remote_user,s.source_marker)=
                (m.environment,m.source,m.meton_user,m.account,m.operation,m.dispatch,m.remote_user,m.source_marker)
            AND s.next_epoch<=m.epoch
    ) SELECT EXISTS(SELECT FROM chain WHERE gen=m.epoch)
$$;

CREATE FUNCTION meton_ledger.claim_recovered_refund_query(route jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE p meton_ledger.refund_dispatch_policies;a meton_ledger.refund_gate_authorities; r meton_ledger.cash_refunds;g meton_ledger.refund_gate_origins;
    d meton_ledger.cash_refund_decisions;b meton_ledger.refund_dispatch_bases;m public.meton_managed_creations;owner jsonb;wire jsonb;request jsonb;s jsonb;
    token_id uuid:=gen_random_uuid();limit_at timestamptz;why text;
BEGIN
    PERFORM meton_ledger.require_cash_writer(route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    SELECT * INTO p FROM meton_ledger.refund_dispatch_policies WHERE (deployment,source,epoch,channel,cash_environment,merchant,app)=
        (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') FOR SHARE;
    SELECT * INTO a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=(p.deployment,p.source,p.epoch) FOR SHARE;
    IF a.key_ref IS NULL OR NOT meton_ledger.active_refund_dispatch_worker(p.deployment,p.source,p.epoch)
        OR (route->>'sourceSystem',route->>'inboxSystem') IS DISTINCT FROM (meton_ledger.notification_system_id(),a.inbox_system)
        OR a.inbox_system=route->>'sourceSystem' THEN RAISE EXCEPTION 'recovered lookup scope unavailable' USING ERRCODE='42501'; END IF;
    SELECT x.* INTO r FROM meton_ledger.cash_refunds x JOIN meton_ledger.refund_gate_origins g0 ON g0.refund=x.refund_id
        JOIN meton_ledger.cash_refund_decisions dec USING(refund_id) JOIN public.meton_managed_creations cm ON cm.source_marker=dec.source_marker
        LEFT JOIN meton_ledger.refund_dispatch_schedule sched ON sched.refund=x.refund_id
        LEFT JOIN meton_ledger.cash_orders ord ON (ord.native_order,ord.source_marker)=(x.native_order,dec.source_marker)
        LEFT JOIN meton_ledger.legacy_cash_facts hist ON (hist.cutoff,hist.kind,hist.native_id)=(x.legacy_cutoff,'order',x.native_order)
        LEFT JOIN meton_ledger.legacy_refund_routes cfg ON (cfg.deployment,cfg.source,cfg.provider_instance)=(cm.environment,cm.source,hist.proof->>'provider_instance')
        WHERE x.phase IN ('held','possibly_sent','unknown') AND (cm.environment,cm.source,cm.epoch)=(p.deployment,p.source,p.epoch)
            AND NOT meton_ledger.dispatch_issuer_current(x.refund_id,route)
            AND (coalesce(ord.channel,cfg.channel),coalesce(ord.cash_environment,cfg.cash_environment),coalesce(ord.merchant_id,cfg.merchant),coalesce(ord.app_id,cfg.app))=
                (p.channel,p.cash_environment,p.merchant,p.app)
            AND (sched.refund IS NULL OR sched.generation<>p.epoch OR sched.state NOT IN ('review','evidence') AND sched.next_at<=clock_timestamp())
        ORDER BY coalesce(sched.next_at,dec.recorded_at),x.refund_id LIMIT 1 FOR UPDATE OF x SKIP LOCKED;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO STRICT g FROM meton_ledger.refund_gate_origins WHERE refund=r.refund_id;
    SELECT * INTO STRICT m FROM public.meton_managed_creations WHERE source_marker=g.marker;
    SELECT * INTO STRICT d FROM meton_ledger.cash_refund_decisions WHERE refund_id=g.refund;
    owner:=jsonb_build_object('environment',m.environment,'source',m.source,'epoch',m.epoch,'user',m.meton_user,'account',m.account,'creation',m.operation,
        'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker,'source_system',route->>'sourceSystem');
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    SELECT * INTO b FROM meton_ledger.refund_dispatch_bases WHERE refund=g.refund;
    limit_at:=least(d.recorded_at+make_interval(secs=>p.query_seconds),b.query_until);
    IF NOT meton_ledger.refund_owner_succeeded(m,g.accepted_epoch) OR g.inbox_system<>a.inbox_system THEN why:='unproved_original_succession';
    ELSIF limit_at<=clock_timestamp() THEN why:='query_window_elapsed';
    ELSE
        IF r.legacy_cutoff IS NOT NULL AND m.epoch<>g.accepted_epoch THEN
            -- 旧截点在 S2 保留原代次。原来已固化的现金仍须匹配原账号的真实订单与两项渠道引用。
            SELECT b.envelope->'cash'||jsonb_build_object('paidAt',b.envelope->'paidAt') INTO wire FROM public.payment_orders z
                JOIN meton_ledger.legacy_cash_handoffs h ON (h.native_order,h.cutoff,h.source_marker)=(z.id,r.legacy_cutoff,m.source_marker)
                WHERE (z.id,z.user_id,z.out_trade_no,z.payment_trade_no)=(r.native_order,m.remote_user,b.envelope#>>'{cash,order}',b.envelope#>>'{cash,transaction}')
                    AND b.envelope->'target'=g.target;
        ELSE wire:=meton_ledger.original_refund_payment(owner,r,route); END IF;
        IF wire IS NULL OR (b.refund IS NOT NULL AND (b.marker,b.envelope->'target',b.envelope->'cash',b.envelope->'paidAt') IS DISTINCT FROM
            (m.source_marker,g.target,wire-'paidAt',wire->'paidAt')) THEN why:='missing_original_payment'; END IF;
    END IF;
    INSERT INTO meton_ledger.refund_dispatch_schedule AS sched(refund,token,generation,next_at,state,reason) VALUES(g.refund,token_id,p.epoch,
        clock_timestamp()+interval '15 seconds',CASE WHEN why IS NULL THEN 'working' ELSE 'review' END,coalesce(why,'recovered_lookup'))
        ON CONFLICT(refund) DO UPDATE SET token=excluded.token,generation=excluded.generation,next_at=excluded.next_at,state=excluded.state,reason=excluded.reason,attempts=sched.attempts+1;
    IF why IS NOT NULL THEN
        UPDATE meton_ledger.cash_refunds SET phase='review',disposition_version=disposition_version+1 WHERE refund_id=g.refund;
        RETURN jsonb_build_object('mode','review','reason',why); END IF;
    s:=jsonb_build_object('deployment',p.deployment,'source',p.source,'epoch',p.epoch,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system,
        'keyRef',a.key_ref,'validUntil',least(limit_at,clock_timestamp()+interval '24 seconds'));
    request:=jsonb_build_object('target',g.target,'cash',wire-'paidAt','paidAt',wire->'paidAt','acceptedAt',d.recorded_at,'originalEpoch',g.accepted_epoch,
        'originalSystem',g.source_system,'originalInbox',g.inbox_system,'channel',p.channel,'cashEnvironment',p.cash_environment,'merchant',p.merchant,'app',p.app,'queryUntil',limit_at);
    RETURN jsonb_build_object('mode','recovered','refund',g.refund,'lease',token_id,'owner',owner,'scope',s,'request',request,
        'permit',encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.recovered.lookup.v1',s,request)::text,'UTF8'),a.seal_key),'hex'));
END $$;

CREATE FUNCTION meton_ledger.finish_recovered_refund_query(owner jsonb,ref uuid,lease_id uuid,result text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE phase_after text;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    IF NOT meton_ledger.active_refund_dispatch_worker(owner->>'environment',owner->>'source',(owner->>'epoch')::bigint) THEN
        RAISE EXCEPTION 'recovered refund reader retired' USING ERRCODE='42501'; END IF;
    IF result IS NULL OR result NOT IN ('unknown','pending','evidence','review') OR NOT EXISTS(SELECT FROM meton_ledger.refund_gate_origins
        WHERE (refund,marker)=(ref,(owner->>'source_marker')::uuid)) THEN RETURN false; END IF;
    UPDATE meton_ledger.refund_dispatch_schedule SET state=result,reason='recovered_'||result,next_at=clock_timestamp()+interval '60 seconds'
        WHERE (refund,token,generation,state,reason)=(ref,lease_id,(owner->>'epoch')::bigint,'working','recovered_lookup');
    IF NOT FOUND THEN RETURN false; END IF;
    phase_after:=CASE WHEN result='review' THEN 'review' ELSE 'unknown' END;
    UPDATE meton_ledger.cash_refunds SET phase=phase_after,disposition_version=disposition_version+1 WHERE refund_id=ref
        AND phase IN ('held','possibly_sent','unknown') AND phase<>phase_after;
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.active_refund_dispatch_worker(text,text,bigint),meton_ledger.record_refund_dispatch_issuer(),meton_ledger.dispatch_issuer_current(uuid,jsonb),
    meton_ledger.refund_owner_succeeded(public.meton_managed_creations,bigint),meton_ledger.claim_recovered_refund_query(jsonb),
    meton_ledger.finish_recovered_refund_query(jsonb,uuid,uuid,text) FROM PUBLIC;
