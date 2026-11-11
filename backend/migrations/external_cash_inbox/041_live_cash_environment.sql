-- 普通微信现金可以是真实环境；保持原商户、写者、人员权限、密文绑定和唯一派发。
-- 不更新已有记录，CREATE OR REPLACE 保留原函数的所有者和受限授权。
ALTER TABLE meton_inbox.cash_review_controllers
    DROP CONSTRAINT cash_review_controllers_cash_environment_check,
    ADD CONSTRAINT cash_review_controllers_cash_environment_check CHECK(cash_environment IN ('isolated','live'));

CREATE OR REPLACE FUNCTION meton_inbox.bind_original_refund_dispatch(s jsonb,t jsonb,permit text,e jsonb,wire_mac text,wanted text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_original_wire_sender(s);
    ref uuid:=(t->>'refund')::uuid; b meton_inbox.refund_wire_bindings; gate jsonb; d meton_inbox.refund_gate_decisions; risk text; allow_claim boolean;
BEGIN
    IF wanted IS NULL OR wanted NOT IN ('claim','query') OR ((s->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE
        OR e->>'format' IS DISTINCT FROM '1' OR e->'target' IS DISTINCT FROM t
        OR (e->'scope')-ARRAY['merchant','app','channel','cashEnvironment'] IS DISTINCT FROM s-'validUntil'
        OR (e#>>'{scope,cashEnvironment}' IN ('isolated','live')) IS NOT TRUE OR
        (e#>>'{scope,channel}',e#>>'{scope,merchant}',e#>>'{scope,app}') IS DISTINCT FROM
            ('wechatpay',e#>>'{cash,merchant}',e#>>'{cash,app}') OR
        (t->>'outRefundNo',t->>'fen') IS DISTINCT FROM (e#>>'{cash,refundOrder}',e#>>'{cash,refundFen}') OR
        wire_mac IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.dispatch.v1',wanted,s,e)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified original refund transport binding' USING ERRCODE='42501'; END IF;
    IF (e->>'queryUntil')::timestamptz<=clock_timestamp() THEN RETURN jsonb_build_object('state','review'); END IF;
    risk:=meton_inbox.original_refund_wire_risk(e);
    IF risk='unindexed' THEN RETURN jsonb_build_object('state','pending'); END IF;
    allow_claim:=wanted='claim' AND risk='clear' AND (e->>'sendUntil')::timestamptz>clock_timestamp();
    INSERT INTO meton_inbox.refund_wire_bindings(refund,envelope,initial_mode,channel,cash_environment,merchant,refund_number)
        VALUES(ref,e,CASE WHEN allow_claim THEN 'claim' ELSE 'query' END,e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',e#>>'{cash,refundOrder}')
        ON CONFLICT DO NOTHING;
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    IF b.envelope IS DISTINCT FROM e THEN RETURN jsonb_build_object('state','review'); END IF;
    IF risk='foreign_attempt' THEN RETURN jsonb_build_object('state','review'); END IF;
    SELECT * INTO d FROM meton_inbox.refund_gate_decisions WHERE refund=ref;
    IF d.refund IS NOT NULL OR allow_claim AND b.initial_mode='claim' THEN
        gate:=meton_inbox.decide_original_refund(s,t,permit,'claimed');
    END IF;
    RETURN jsonb_build_object('state',CASE meton_inbox.original_refund_query_result(ref) WHEN 'review' THEN 'review' WHEN 'evidence' THEN 'evidence'
        ELSE 'ready' END,'gate',gate);
END $$;

CREATE OR REPLACE FUNCTION meton_inbox.require_refund_aftercare_reviewer(route jsonb) RETURNS meton_inbox.refund_gate_authorities
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities;
BEGIN
    SELECT g.* INTO a FROM meton_inbox.refund_gate_authorities g JOIN meton_inbox.refund_aftercare_review_roles p USING(deployment,source,epoch,key_ref)
        JOIN meton_inbox.writers w ON (w.deployment,w.source_name,w.generation,w.source_system)=(g.deployment,g.source,g.epoch,g.source_system)
        WHERE (g.deployment,g.source,g.epoch,g.source_system,w.channel,w.cash_environment,w.merchant,w.app,p.reviewer)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'sourceSystem',route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',session_user)
            AND route->>'cashEnvironment' IN ('isolated','live') AND g.sender<>p.reviewer AND g.stopper<>p.reviewer AND w.writer<>p.reviewer
            AND NOT EXISTS(SELECT FROM meton_inbox.refund_resolution_roles r WHERE r.resolver=p.reviewer) FOR SHARE OF g,p,w;
    IF a.key_ref IS NULL OR route->>'inboxSystem' IS DISTINCT FROM meton_inbox.system_id() OR a.source_system=meton_inbox.system_id()
        OR pg_is_in_recovery() OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
        OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') OR current_setting('transaction_isolation')<>'read committed'
        OR current_setting('session_replication_role')<>'origin' OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_inbox','CREATE')
        OR EXISTS(SELECT FROM pg_roles r WHERE (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls) AND pg_has_role(session_user,r.oid,'MEMBER'))
        OR EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
            (has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE') OR has_table_privilege(session_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted original payer reviewer unavailable' USING ERRCODE='42501'; END IF;
    RETURN a;
END $$;

CREATE OR REPLACE FUNCTION meton_inbox.lock_cash_review_controller(route jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_inbox.cash_review_controllers;
BEGIN
    IF jsonb_typeof(route) IS DISTINCT FROM 'object' OR
        (route ?& ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']) IS NOT TRUE OR
        route-ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']<>'{}'::jsonb OR
        (route->>'cashEnvironment' IN ('isolated','live')) IS NOT TRUE OR current_setting('transaction_read_only')<>'off' OR
        current_setting('transaction_isolation')<>'read committed' OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR
        current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') THEN
        RAISE EXCEPTION 'current durable original review scope required' USING ERRCODE='25006'; END IF;
    SELECT x.* INTO r FROM meton_inbox.cash_review_controllers x JOIN meton_inbox.refund_gate_authorities a
        USING(deployment,source,epoch,key_ref,source_system)
        JOIN meton_inbox.refund_aftercare_review_roles p USING(deployment,source,epoch,key_ref)
        WHERE (x.deployment,x.source,x.epoch,x.key_ref,x.source_system,x.channel,x.cash_environment,x.merchant,x.controller,p.reviewer)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,(route->>'keyRef')::uuid,route->>'sourceSystem',
             route->>'channel',route->>'cashEnvironment',route->>'merchant',session_user::name,session_user::name)
        AND meton_inbox.system_id()=route->>'inboxSystem' AND x.source_system<>meton_inbox.system_id() FOR SHARE OF x,a,p;
    IF r.controller IS NULL THEN RAISE EXCEPTION 'cash review controller retired' USING ERRCODE='42501'; END IF;
    PERFORM FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(r.channel,r.cash_environment,r.merchant) FOR SHARE;
    IF NOT FOUND OR EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(r.channel,r.cash_environment,r.merchant) AND
        (w.deployment,w.source_name,w.generation,w.source_system)<>(r.deployment,r.source,r.epoch,r.source_system)) OR
        EXISTS(SELECT FROM pg_roles p WHERE p.rolname=session_user AND (p.rolsuper OR p.rolinherit OR p.rolcreatedb OR p.rolcreaterole OR p.rolreplication OR p.rolbypassrls)) OR
        EXISTS(SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=session_user)) OR
        has_schema_privilege(session_user,'meton_inbox','CREATE') OR has_schema_privilege(session_user,'public','CREATE') OR
        EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
            (has_table_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
             has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) OR
        EXISTS(SELECT FROM pg_proc p WHERE p.pronamespace='meton_inbox'::regnamespace AND p.oid NOT IN
            ('meton_inbox.system_id()'::regprocedure,'meton_inbox.cash_manual_review_ready(jsonb)'::regprocedure,
             'meton_inbox.cash_manual_review_context(jsonb,text)'::regprocedure,
             'meton_inbox.cash_manual_review(jsonb,jsonb,text,bytea,text)'::regprocedure) AND has_function_privilege(session_user,p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'separate current cash review controller required' USING ERRCODE='42501'; END IF;
END $$;

CREATE OR REPLACE FUNCTION meton_inbox.record_original_alternative_approval(route jsonb,ref uuid,op uuid,f jsonb,key_reference text,evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_aftercare_reviewer(route);b meton_inbox.refund_aftercare_origins;
    v meton_inbox.refund_aftercare_results;saved meton_inbox.refund_alternative_approvals;
BEGIN
    -- 现有替代渠道仅是模拟协议，扩展普通现金环境不授予真实替代付款资格。
    IF route->>'cashEnvironment' IS DISTINCT FROM 'isolated' THEN
        RAISE EXCEPTION 'isolated alternative rail required' USING ERRCODE='42501'; END IF;
    SELECT * INTO b FROM meton_inbox.refund_aftercare_origins WHERE refund=ref;
    IF b.refund IS NULL OR (b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}',b.envelope#>>'{scope,channel}',
        b.envelope#>>'{scope,cashEnvironment}',b.envelope#>>'{scope,merchant}',b.envelope#>>'{scope,app}') IS DISTINCT FROM
        (a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN
        RAISE EXCEPTION 'original approval owner unavailable' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(route,b.envelope#>>'{cash,order}',b.envelope#>>'{cash,transaction}');
    IF op IS NULL OR (f->>'format'='1' AND f->>'refund'=ref::text AND (f->>'verificationRevision')::bigint>0 AND
        f->>'verificationHash'~'^[0-9a-f]{64}$' AND f->>'beneficiaryHash'~'^[0-9a-f]{64}$' AND f->>'materialHash'~'^[0-9a-f]{64}$'
        AND f->>'approvalReference'~'^[A-Za-z0-9_.:-]{1,120}$' AND f->>'rail'='meton-isolated-transfer' AND
        f->>'merchant'~'^[A-Za-z0-9_.:-]{1,80}$' AND length(key_reference) BETWEEN 1 AND 120 AND octet_length(evidence) BETWEEN 29 AND 1572864) IS NOT TRUE OR
        f-ARRAY['format','refund','verificationRevision','verificationHash','beneficiaryHash','materialHash','approvalReference','rail','merchant']<>'{}'::jsonb THEN
        RAISE EXCEPTION 'invalid original alternative approval' USING ERRCODE='22023'; END IF;
    SELECT * INTO saved FROM meton_inbox.refund_alternative_approvals WHERE (refund,operation)=(ref,op);
    IF FOUND THEN
        IF saved.facts IS DISTINCT FROM f THEN RAISE EXCEPTION 'approval operation reused' USING ERRCODE='22023'; END IF;
        RETURN 'recorded';
    END IF;
    SELECT * INTO v FROM meton_inbox.refund_aftercare_results WHERE refund=ref ORDER BY revision DESC LIMIT 1;
    IF v.revision IS DISTINCT FROM (f->>'verificationRevision')::bigint OR encode(v.digest,'hex') IS DISTINCT FROM f->>'verificationHash' OR
        (v.verification->>'payerState',v.verification->>'channelState') IS DISTINCT FROM ('verified','closed_unpaid') OR
        NOT EXISTS(SELECT FROM meton_inbox.refund_payer_reviews r WHERE r.refund=ref AND r.facts->>'outcome'='matched' AND r.facts->>'beneficiaryHash'=f->>'beneficiaryHash') OR
        EXISTS(SELECT FROM meton_inbox.refund_alternative_decisions WHERE refund=ref) THEN
        RAISE EXCEPTION 'original verification changed or already decided' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.refund_alternative_approvals(refund,operation,facts,digest,key_ref,sealed,reviewer,reviewed_epoch)
        VALUES(ref,op,f,sha256(convert_to(f::text,'UTF8')),key_reference,evidence,session_user,a.epoch);
    IF EXISTS(SELECT FROM meton_inbox.refund_wire_bindings WHERE refund=ref) THEN PERFORM meton_inbox.wake_refund_settlement(ref); END IF;
    RETURN 'recorded';
END $$;
