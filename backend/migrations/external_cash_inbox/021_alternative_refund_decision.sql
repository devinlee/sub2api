-- 审批与独立执行选择分开保存。审批本身不是发送凭据，更不是资金已退的证据。
CREATE TABLE meton_inbox.refund_alternative_approvals(
    refund uuid NOT NULL REFERENCES meton_inbox.refund_aftercare_origins,operation uuid NOT NULL,
    sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE, facts jsonb NOT NULL, digest bytea NOT NULL CHECK(octet_length(digest)=32),
    key_ref text NOT NULL CHECK(length(key_ref) BETWEEN 1 AND 120),sealed bytea NOT NULL CHECK(octet_length(sealed) BETWEEN 29 AND 1572864),
    reviewer name NOT NULL,reviewed_epoch bigint NOT NULL,recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),PRIMARY KEY(refund,operation)
);
CREATE TABLE meton_inbox.refund_alternative_decisions(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_aftercare_origins,proposal jsonb NOT NULL,
    choice text NOT NULL CHECK(choice IN ('reserved','abandoned')),ticket uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
DO $protect$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['refund_alternative_approvals','refund_alternative_decisions'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
        EXECUTE format('REVOKE ALL ON meton_inbox.%I FROM PUBLIC',n);
    END LOOP;
END $protect$;

/** 测试审核员批准明确的一份核验材料和收款归属；程序随后仍须重新核对原冻结、原路事实与现金上限。 */
CREATE FUNCTION meton_inbox.record_original_alternative_approval(route jsonb,ref uuid,op uuid,f jsonb,key_reference text,evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_aftercare_reviewer(route);b meton_inbox.refund_aftercare_origins;
    v meton_inbox.refund_aftercare_results;saved meton_inbox.refund_alternative_approvals;
BEGIN
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

-- 复用既有现金汇总算法；替代批准即使没有强制冲正也必须检查已知原退款及原付款人实际出资上限。
DO $reuse$
DECLARE body text:=pg_get_functiondef('meton_inbox.original_cash_return_exposure(meton_inbox.refund_wire_bindings)'::regprocedure);
    point text:='IF (x->>''events'')::bigint=0 THEN RETURN NULL; END IF;';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'cash exposure algorithm changed'; END IF;
    body:=replace(body,'meton_inbox.original_cash_return_exposure(','meton_inbox.all_original_cash_return_exposure(');
    EXECUTE replace(body,point,'');
END $reuse$;
REVOKE ALL ON FUNCTION meton_inbox.all_original_cash_return_exposure(meton_inbox.refund_wire_bindings) FROM PUBLIC;

/** 独立选择已提交后，按当前代次重签原回执；读回不重新授予选择权，也不代表发生付款。 */
CREATE FUNCTION meton_inbox.original_alternative_decision(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);d meton_inbox.refund_alternative_decisions;e jsonb;f jsonb;
BEGIN
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref;
    IF d.refund IS NULL THEN RETURN jsonb_build_object('state','undecided'); END IF;
    e:=d.proposal->'envelope';
    IF (e#>>'{scope,deployment}',e#>>'{scope,source}',e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',e#>>'{scope,app}') IS DISTINCT FROM
        (a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN
        RAISE EXCEPTION 'original alternative route differs' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(route,e#>>'{cash,order}',e#>>'{cash,transaction}');
    IF d.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    f:=jsonb_build_object('format',1,'scope',jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id()),'proposal',d.proposal,'choice',d.choice,'ticket',d.ticket,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','decision_proved','facts',f,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.alternative.decided.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 只签出当前批准；所有原路尝试和已知返还共同约束原现金上限，来源 R 另在来源原事务复验。 */
CREATE FUNCTION meton_inbox.original_alternative_material(route jsonb,ref uuid,op uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);b meton_inbox.refund_wire_bindings;
    approval meton_inbox.refund_alternative_approvals;d meton_inbox.refund_alternative_decisions;other meton_inbox.refund_wire_bindings;
    check_result jsonb;exposure jsonb;reserved numeric;scope jsonb;proposal jsonb;f jsonb;cash_key bytea;latest bigint;
BEGIN
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref;
    IF FOUND THEN
        IF op IS NOT NULL AND d.proposal->>'approval' IS DISTINCT FROM op::text THEN RETURN jsonb_build_object('state','superseded'); END IF;
        RETURN meton_inbox.original_alternative_decision(route,ref);
    END IF;
    SELECT * INTO approval FROM meton_inbox.refund_alternative_approvals WHERE refund=ref AND (op IS NULL OR operation=op) ORDER BY sequence DESC LIMIT 1;
    IF NOT FOUND THEN RETURN jsonb_build_object('state','not_requested'); END IF;
    SELECT max(sequence) INTO latest FROM meton_inbox.refund_alternative_approvals WHERE refund=ref;
    IF approval.sequence<>latest THEN RETURN jsonb_build_object('state','superseded'); END IF;
    check_result:=meton_inbox.original_refund_aftercare_result(route,ref);
    IF check_result->>'state'='recorded' THEN RETURN check_result; END IF;
    IF check_result->>'state' IS DISTINCT FROM 'verification_proved' OR
        (check_result#>>'{facts,verification,payerState}',check_result#>>'{facts,verification,channelState}',check_result#>>'{facts,evidenceHash}') IS DISTINCT FROM
        ('verified','closed_unpaid',approval.facts->>'verificationHash') THEN RETURN jsonb_build_object('state','verification_required'); END IF;
    SELECT * INTO STRICT b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    cash_key:=meton_inbox.cash_original_identity(b.envelope);
    FOR other IN SELECT * FROM meton_inbox.refund_wire_bindings x WHERE x.refund<>ref AND meton_inbox.cash_original_identity(x.envelope)=cash_key LOOP
        check_result:=meton_inbox.original_refund_cash_result(route,other.refund);
        IF check_result->>'state'='recorded' THEN RETURN check_result; END IF;
        IF check_result->>'state' NOT IN ('success_proved','closed_observed') THEN RETURN jsonb_build_object('state','other_cash_pending'); END IF;
        IF EXISTS(SELECT FROM meton_inbox.refund_gate_decisions g WHERE g.refund=other.refund AND g.choice='claimed' AND NOT EXISTS(
            SELECT FROM meton_inbox.refund_sender_retirements r WHERE r.refund=other.refund AND r.ticket=g.ticket)) THEN
            RETURN jsonb_build_object('state','other_sender_pending'); END IF;
    END LOOP;
    exposure:=meton_inbox.all_original_cash_return_exposure(b);
    SELECT coalesce(sum((x.proposal#>>'{payment,fen}')::numeric),0) INTO reserved FROM meton_inbox.refund_alternative_decisions x
        WHERE x.choice='reserved' AND x.refund<>ref AND meton_inbox.cash_original_identity(x.proposal->'envelope')=cash_key;
    IF exposure->>'payerCapFen' IS NULL OR (exposure->>'pendingCommit')::boolean OR
        ((exposure->>'ambiguousExternalEvents')::bigint=0 AND (exposure->>'ambiguousRefundEvents')::bigint=0 AND
        (exposure->>'knownReturnedFen')::numeric+reserved+(b.envelope#>>'{cash,refundFen}')::numeric<=(exposure->>'payerCapFen')::numeric) IS NOT TRUE THEN
        RETURN jsonb_build_object('state','cash_cap_review'); END IF;
    proposal:=jsonb_build_object('format',1,'refund',ref,'intent',b.envelope#>'{target,intent}','envelope',b.envelope,
        'approval',approval.operation,'approvalHash',encode(approval.digest,'hex'),'verificationHash',approval.facts->'verificationHash',
        'payment',jsonb_build_object('rail',approval.facts->'rail','environment','isolated','merchant',approval.facts->'merchant','order','A'||replace(ref::text,'-',''),
            'beneficiaryHash',approval.facts->'beneficiaryHash','currency','CNY','fen',b.envelope#>'{cash,refundFen}'));
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    f:=jsonb_build_object('format',1,'scope',scope,'proposal',proposal,'cashExposure',exposure,'otherAlternativeFen',reserved::text,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','approval_ready','facts',f,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.alternative.approval.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 原意图只能确定选择一次。撤回与准备并发，胜者永久留下；迟到工作不能把撤回改成准备。 */
CREATE FUNCTION meton_inbox.decide_original_alternative(route jsonb,proof jsonb,want text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);f jsonb:=proof->'facts';p jsonb:=f->'proposal';e jsonb:=p->'envelope';
    ref uuid:=(p->>'refund')::uuid;scope jsonb;d meton_inbox.refund_alternative_decisions;current_material jsonb;
BEGIN
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    IF want IS NULL OR want NOT IN ('reserve','abandon') OR proof->>'state' IS DISTINCT FROM 'source_ready' OR f->'scope' IS DISTINCT FROM scope OR
        f->>'format' IS DISTINCT FROM '1' OR ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds' AND
        ref::text=e#>>'{target,refund}') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.'||want||'.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified alternative source hold' USING ERRCODE='42501'; END IF;
    IF NOT EXISTS(SELECT FROM meton_inbox.refund_aftercare_origins WHERE refund=ref AND envelope=e) OR
        (e#>>'{scope,deployment}',e#>>'{scope,source}',e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',e#>>'{scope,app}') IS DISTINCT FROM
        (a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN
        RAISE EXCEPTION 'alternative original route differs' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(route,e#>>'{cash,order}',e#>>'{cash,transaction}');
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.refund.transport.v1/'||ref::text,0));
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref;
    IF FOUND THEN
        IF d.proposal IS DISTINCT FROM p THEN RAISE EXCEPTION 'alternative original proposal changed' USING ERRCODE='42501'; END IF;
        RETURN meton_inbox.original_alternative_decision(route,ref);
    END IF;
    IF want='reserve' THEN
        current_material:=meton_inbox.original_alternative_material(route,ref,(p->>'approval')::uuid);
        IF current_material->>'state' IS DISTINCT FROM 'approval_ready' THEN RETURN current_material; END IF;
        IF current_material#>'{facts,proposal}' IS DISTINCT FROM p THEN RAISE EXCEPTION 'alternative approval superseded' USING ERRCODE='42501'; END IF;
    END IF;
    INSERT INTO meton_inbox.refund_alternative_decisions(refund,proposal,choice) VALUES(ref,p,CASE want WHEN 'reserve' THEN 'reserved' ELSE 'abandoned' END);
    RETURN meton_inbox.original_alternative_decision(route,ref);
END $$;

-- 原路发送永远不能越过替代选择。归档已撤回的替代仍保留原路关闭事实，不制造另一张退款。
DO $barrier$
DECLARE body text;point text;
BEGIN
    body:=pg_get_functiondef('meton_inbox.original_refund_wire_risk(jsonb)'::regprocedure);
    point:='RETURN ''clear'';';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original refund risk changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_inbox.refund_alternative_decisions WHERE refund=(e#>>''{target,refund}'')::uuid AND choice=''reserved'') THEN RETURN ''alternative_reserved''; END IF; '||point);
    body:=pg_get_functiondef('meton_inbox.original_refund_aftercare_result(jsonb,uuid)'::regprocedure);
    point:='risk NOT IN (''clear'',''observed'')';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original aftercare risk changed'; END IF;
    EXECUTE replace(body,point,'risk NOT IN (''clear'',''observed'',''alternative_reserved'')');
    body:=pg_get_functiondef('meton_inbox.start_original_refund_transport(jsonb,uuid,uuid,text)'::regprocedure);
    point:='IF send_secret IS NULL';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original sender start changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice=''reserved'') THEN RETURN NULL; END IF; '||point);
    body:=pg_get_functiondef('meton_inbox.hold_original_refund_transport(jsonb,uuid,uuid,text)'::regprocedure);
    point:='IF io_secret IS NULL';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original sender hold changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice=''reserved'') THEN RETURN false; END IF; '||point);
END $barrier$;
REVOKE ALL ON FUNCTION meton_inbox.record_original_alternative_approval(jsonb,uuid,uuid,jsonb,text,bytea),meton_inbox.original_alternative_decision(jsonb,uuid),
    meton_inbox.original_alternative_material(jsonb,uuid,uuid),meton_inbox.decide_original_alternative(jsonb,jsonb,text) FROM PUBLIC;
