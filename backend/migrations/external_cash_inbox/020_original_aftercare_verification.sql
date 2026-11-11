-- 人工核验和渠道结论分别留存。审核员只能提交原付款人的核验材料，不能签现金成功、发送退款或修改余额。
CREATE TABLE meton_inbox.refund_aftercare_origins(
    refund uuid PRIMARY KEY, envelope jsonb NOT NULL, reason text NOT NULL,
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE TABLE meton_inbox.refund_aftercare_review_roles(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,key_ref uuid NOT NULL,reviewer name NOT NULL,
    PRIMARY KEY(deployment,source,epoch,key_ref),UNIQUE(deployment,source,reviewer)
);
CREATE TABLE meton_inbox.refund_payer_reviews(
    refund uuid NOT NULL REFERENCES meton_inbox.refund_aftercare_origins, operation uuid NOT NULL,
    facts jsonb NOT NULL, digest bytea NOT NULL CHECK(octet_length(digest)=32),
    key_ref text NOT NULL CHECK(length(key_ref) BETWEEN 1 AND 120), sealed bytea NOT NULL CHECK(octet_length(sealed) BETWEEN 29 AND 1572864),
    reviewer name NOT NULL, reviewed_epoch bigint NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),PRIMARY KEY(refund,operation)
);
CREATE TABLE meton_inbox.refund_aftercare_results(
    revision bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, refund uuid NOT NULL REFERENCES meton_inbox.refund_aftercare_origins,
    digest bytea NOT NULL CHECK(octet_length(digest)=32), verification jsonb NOT NULL,
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE INDEX refund_aftercare_result_latest ON meton_inbox.refund_aftercare_results(refund,revision DESC);
DO $protect$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['refund_aftercare_origins','refund_aftercare_review_roles','refund_payer_reviews','refund_aftercare_results'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
        EXECUTE format('REVOKE ALL ON meton_inbox.%I FROM PUBLIC',n);
    END LOOP;
END $protect$;

/** 只有当前来源签出的原售后可以进入归档；客户端自报的账户和付款份额不参加归属选择。 */
CREATE FUNCTION meton_inbox.bind_original_refund_aftercare(route jsonb,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route); f jsonb:=proof->'facts'; e jsonb:=f->'envelope';
    s jsonb; ref uuid:=(e#>>'{target,refund}')::uuid; saved meton_inbox.refund_aftercare_origins;
BEGIN
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    IF proof->>'state' IS DISTINCT FROM 'ready' OR f->>'format' IS DISTINCT FROM '1' OR f->'scope' IS DISTINCT FROM s OR
        (f->>'reason' IN ('window_elapsed','payer_account_unavailable') AND ref IS NOT NULL AND
        (f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        (e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',e#>>'{scope,app}',e#>>'{scope,deployment}',e#>>'{scope,source}') IS DISTINCT FROM
            (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',a.deployment,a.source) OR
        proof->>'mac' IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.aftercare.origin.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified original aftercare' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(route,e#>>'{cash,order}',e#>>'{cash,transaction}');
    IF EXISTS(SELECT FROM meton_inbox.refund_wire_bindings WHERE refund=ref AND envelope<>e) THEN
        RAISE EXCEPTION 'original aftercare envelope differs' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.refund_aftercare_origins VALUES(ref,e,f->>'reason') ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT saved FROM meton_inbox.refund_aftercare_origins WHERE refund=ref;
    IF (saved.envelope,saved.reason) IS DISTINCT FROM (e,f->>'reason') THEN
        RAISE EXCEPTION 'original aftercare identity changed' USING ERRCODE='42501'; END IF;
    RETURN 'bound';
END $$;

/** 当前隔离审核身份独立于发送、收件和结清身份；禁止表读写及角色继承绕过。 */
CREATE FUNCTION meton_inbox.require_refund_aftercare_reviewer(route jsonb) RETURNS meton_inbox.refund_gate_authorities
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities;
BEGIN
    SELECT g.* INTO a FROM meton_inbox.refund_gate_authorities g JOIN meton_inbox.refund_aftercare_review_roles p USING(deployment,source,epoch,key_ref)
        JOIN meton_inbox.writers w ON (w.deployment,w.source_name,w.generation,w.source_system)=(g.deployment,g.source,g.epoch,g.source_system)
        WHERE (g.deployment,g.source,g.epoch,g.source_system,w.channel,w.cash_environment,w.merchant,w.app,p.reviewer)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'sourceSystem',route->>'channel','isolated',route->>'merchant',route->>'app',session_user)
            AND route->>'cashEnvironment'='isolated' AND g.sender<>p.reviewer AND g.stopper<>p.reviewer AND w.writer<>p.reviewer
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

/** 测试审核员须提交原付款人及收款归属核验材料。该结论不是渠道查单、替代批准或付款凭证。 */
CREATE FUNCTION meton_inbox.record_original_payer_review(route jsonb,ref uuid,op uuid,f jsonb,key_reference text,evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_aftercare_reviewer(route); b meton_inbox.refund_aftercare_origins;
    saved meton_inbox.refund_payer_reviews; hash bytea;
BEGIN
    SELECT * INTO b FROM meton_inbox.refund_aftercare_origins WHERE refund=ref;
    IF b.refund IS NULL OR (b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}',b.envelope#>>'{scope,channel}',
        b.envelope#>>'{scope,cashEnvironment}',b.envelope#>>'{scope,merchant}',b.envelope#>>'{scope,app}') IS DISTINCT FROM
        (a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN
        RAISE EXCEPTION 'original payer review unavailable' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(route,b.envelope#>>'{cash,order}',b.envelope#>>'{cash,transaction}');
    IF op IS NULL OR (f->>'format'='1' AND f->>'refund'=ref::text AND f->>'outcome' IN ('matched','rejected') AND
        f->>'originalPayerHash'~'^[0-9a-f]{64}$' AND f->>'beneficiaryHash'~'^[0-9a-f]{64}$' AND f->>'materialHash'~'^[0-9a-f]{64}$' AND
        f->>'reviewReference'~'^[A-Za-z0-9_.:-]{1,120}$' AND length(key_reference) BETWEEN 1 AND 120 AND octet_length(evidence) BETWEEN 29 AND 1572864) IS NOT TRUE OR
        (f->>'order',f->>'transaction') IS DISTINCT FROM (b.envelope#>>'{cash,order}',b.envelope#>>'{cash,transaction}') OR
        f-ARRAY['format','refund','order','transaction','outcome','originalPayerHash','beneficiaryHash','materialHash','reviewReference']<>'{}'::jsonb THEN
        RAISE EXCEPTION 'incomplete original payer review material' USING ERRCODE='22023'; END IF;
    hash:=sha256(convert_to(f::text,'UTF8'));
    SELECT * INTO saved FROM meton_inbox.refund_payer_reviews WHERE (refund,operation)=(ref,op);
    IF FOUND THEN
        IF saved.facts IS DISTINCT FROM f THEN RAISE EXCEPTION 'payer review operation reused' USING ERRCODE='22023'; END IF;
        RETURN 'recorded';
    END IF;
    INSERT INTO meton_inbox.refund_payer_reviews(refund,operation,facts,digest,key_ref,sealed,reviewer,reviewed_epoch)
        VALUES(ref,op,f,hash,key_reference,evidence,session_user,a.epoch);
    IF EXISTS(SELECT FROM meton_inbox.refund_wire_bindings WHERE refund=ref) THEN PERFORM meton_inbox.wake_refund_settlement(ref); END IF;
    RETURN 'recorded';
END $$;

/** 渠道结论只读取原验真事实。没有记录、窗口已过或查不到，不足以证明没有在途或已退。 */
CREATE FUNCTION meton_inbox.original_refund_aftercare_result(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route); b meton_inbox.refund_aftercare_origins;
    wire meton_inbox.refund_wire_bindings; d meton_inbox.refund_gate_decisions; saved meton_inbox.refund_aftercare_results;
    payer text:='unverified';channel text:='unknown';cash jsonb;summary jsonb;facts jsonb;scope jsonb;hash bytea;
    reports text;channel_reports text;variants bigint;outcomes text[];fresh boolean;closed_evidence boolean;drained boolean:=false;risk text;
BEGIN
    SELECT * INTO b FROM meton_inbox.refund_aftercare_origins WHERE refund=ref;
    IF b.refund IS NULL OR (b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}',b.envelope#>>'{scope,channel}',
        b.envelope#>>'{scope,cashEnvironment}',b.envelope#>>'{scope,merchant}',b.envelope#>>'{scope,app}') IS DISTINCT FROM
        (a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN RETURN jsonb_build_object('state','unbound'); END IF;
    PERFORM meton_inbox.lock_original_cash(route,b.envelope#>>'{cash,order}',b.envelope#>>'{cash,transaction}');
    SELECT string_agg(encode(v.digest,'hex'),',' ORDER BY v.operation),count(DISTINCT jsonb_build_array(v.facts->'outcome',v.facts->'originalPayerHash',v.facts->'beneficiaryHash')),
        array_agg(DISTINCT v.facts->>'outcome'),coalesce(bool_or(v.recorded_xid=pg_current_xact_id()),false)
        INTO reports,variants,outcomes,fresh FROM meton_inbox.refund_payer_reviews v WHERE v.refund=ref;
    IF variants>1 THEN payer:='review'; ELSIF outcomes[1]='matched' THEN payer:='verified'; ELSIF outcomes[1]='rejected' THEN payer:='rejected'; END IF;
    SELECT * INTO wire FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    IF wire.refund IS NOT NULL AND wire.envelope=b.envelope THEN
        cash:=meton_inbox.original_refund_cash_result(route,ref);
        IF cash->>'state'='recorded' THEN RETURN cash; END IF;
        risk:=meton_inbox.original_refund_wire_risk(b.envelope);
        IF risk NOT IN ('clear','observed') OR cash->>'state'='review' THEN channel:='review';
        ELSIF cash->>'state'='success_proved' THEN channel:='original_paid';
        ELSIF cash->>'state'='closed_observed' THEN
            SELECT EXISTS(SELECT FROM meton_inbox.refund_resolution_samples(wire) WHERE transport IN ('GET','callback') AND reported='CLOSED' AND correct_owner AND NOT conflicted) INTO closed_evidence;
            -- 与原发送者共用传输锁；已取得出站权的旧进程必须退出并被永久退役。
            PERFORM pg_advisory_xact_lock(hashtextextended('meton.refund.transport.v1/'||ref::text,0));
            SELECT * INTO d FROM meton_inbox.refund_gate_decisions WHERE refund=ref;
            drained:=(d.refund IS NULL AND wire.initial_mode='query') OR d.choice='stopped' OR EXISTS(
                SELECT FROM meton_inbox.refund_sender_retirements WHERE refund=ref AND ticket=d.ticket);
            channel:=CASE WHEN closed_evidence AND coalesce(drained,false) THEN 'closed_unpaid' ELSE 'pending' END;
        ELSE channel:='pending'; END IF;
    ELSIF wire.refund IS NOT NULL THEN channel:='review'; END IF;
    SELECT string_agg(encode(sha256(convert_to(jsonb_build_array(transport,reported,fields,correct_owner,conflicted)::text,'UTF8')),'hex'),','
        ORDER BY transport,reported,fields::text) INTO channel_reports FROM meton_inbox.refund_resolution_samples(wire);
    summary:=jsonb_build_object('payerState',payer,'channelState',channel,'payerEvidence',coalesce(reports,''),
        'channelEvidence',coalesce(channel_reports,''),'senderDrained',coalesce(drained,false),'risk',risk);
    hash:=sha256(convert_to(summary::text,'UTF8'));
    SELECT * INTO saved FROM meton_inbox.refund_aftercare_results WHERE refund=ref ORDER BY revision DESC LIMIT 1;
    -- 未索引通知解除后也会回到先前状态；每次实际变化必须得到更高序号，不能复用较旧快照压过新结论。
    IF saved.digest IS DISTINCT FROM hash THEN
        INSERT INTO meton_inbox.refund_aftercare_results(refund,digest,verification) VALUES(ref,hash,summary) RETURNING * INTO saved;
    END IF;
    IF fresh OR b.recorded_xid=pg_current_xact_id() OR saved.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    facts:=jsonb_build_object('format',1,'scope',scope,'envelope',b.envelope,'revision',saved.revision,'verification',summary,
        'evidenceHash',encode(hash,'hex'),'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','verification_proved','facts',facts,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.aftercare.verified.v1',facts)::text,'UTF8'),a.seal_key),'hex'));
END $$;
REVOKE ALL ON FUNCTION meton_inbox.bind_original_refund_aftercare(jsonb,jsonb),meton_inbox.require_refund_aftercare_reviewer(jsonb),
    meton_inbox.record_original_payer_review(jsonb,uuid,uuid,jsonb,text,bytea),meton_inbox.original_refund_aftercare_result(jsonb,uuid) FROM PUBLIC;
