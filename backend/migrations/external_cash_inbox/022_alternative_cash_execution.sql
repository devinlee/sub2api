-- 派发声明先持久化，一次发送秘密只交给首次确定提交的调用；丢响应、重启及重领只允许原号查询。
CREATE TABLE meton_inbox.alternative_cash_attempts(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_alternative_decisions,scope jsonb NOT NULL,
    secret_hash bytea NOT NULL CHECK(octet_length(secret_hash)=32),valid_until timestamptz NOT NULL,
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE TABLE meton_inbox.alternative_cash_uses(refund uuid PRIMARY KEY REFERENCES meton_inbox.alternative_cash_attempts);
CREATE TABLE meton_inbox.alternative_cash_observations(
    refund uuid NOT NULL REFERENCES meton_inbox.refund_alternative_decisions,verb text NOT NULL CHECK(verb IN ('POST','GET')),
    digest bytea NOT NULL CHECK(octet_length(digest)=32),facts jsonb NOT NULL,key_ref text NOT NULL CHECK(length(key_ref) BETWEEN 1 AND 120),
    sealed bytea NOT NULL CHECK(octet_length(sealed) BETWEEN 29 AND 1572864),recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),PRIMARY KEY(refund,verb,digest)
);
CREATE TABLE meton_inbox.alternative_cash_positive(
    refund uuid NOT NULL REFERENCES meton_inbox.refund_alternative_decisions,economic_hash bytea NOT NULL CHECK(octet_length(economic_hash)=32),
    cash jsonb NOT NULL,recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),PRIMARY KEY(refund,economic_hash)
);
CREATE TABLE meton_inbox.alternative_cash_jobs(refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_alternative_decisions,
    token uuid,next_at timestamptz NOT NULL,state text NOT NULL);
DO $protect$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['alternative_cash_attempts','alternative_cash_uses','alternative_cash_observations','alternative_cash_positive'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
        EXECUTE format('REVOKE ALL ON meton_inbox.%I FROM PUBLIC',n);
    END LOOP;
END $protect$;
REVOKE ALL ON meton_inbox.alternative_cash_jobs FROM PUBLIC;

/** 新准备进入独立执行队列；队列不是发送许可，所有现金动作仍由原决策和原份额约束。 */
CREATE FUNCTION meton_inbox.schedule_alternative_cash() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NEW.choice='reserved' THEN INSERT INTO meton_inbox.alternative_cash_jobs VALUES(NEW.refund,NULL,clock_timestamp(),'ready') ON CONFLICT DO NOTHING; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER alternative_cash_arrived AFTER INSERT ON meton_inbox.refund_alternative_decisions FOR EACH ROW EXECUTE FUNCTION meton_inbox.schedule_alternative_cash();
ALTER TABLE meton_inbox.refund_alternative_decisions ENABLE ALWAYS TRIGGER alternative_cash_arrived;
INSERT INTO meton_inbox.alternative_cash_jobs SELECT refund,NULL,clock_timestamp(),'ready' FROM meton_inbox.refund_alternative_decisions WHERE choice='reserved';

/** 只在当前原付款路由领取，旧节点不能确认新租约。 */
CREATE FUNCTION meton_inbox.claim_alternative_cash(route jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);j meton_inbox.alternative_cash_jobs;
BEGIN
    SELECT x.* INTO j FROM meton_inbox.alternative_cash_jobs x JOIN meton_inbox.refund_alternative_decisions d USING(refund)
        WHERE x.next_at<=clock_timestamp() AND (d.proposal#>>'{envelope,scope,deployment}',d.proposal#>>'{envelope,scope,source}',
        d.proposal#>>'{envelope,scope,channel}',d.proposal#>>'{envelope,scope,cashEnvironment}',d.proposal#>>'{envelope,scope,merchant}',d.proposal#>>'{envelope,scope,app}')=
        (a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') ORDER BY x.next_at,x.refund LIMIT 1 FOR UPDATE OF x SKIP LOCKED;
    IF NOT FOUND THEN RETURN NULL; END IF;
    UPDATE meton_inbox.alternative_cash_jobs SET token=gen_random_uuid(),next_at=clock_timestamp()+interval '20 seconds',state='working' WHERE refund=j.refund RETURNING * INTO j;
    RETURN jsonb_build_object('refund',j.refund,'token',j.token);
END $$;
CREATE FUNCTION meton_inbox.finish_alternative_cash(route jsonb,ref uuid,lease uuid,result text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.require_refund_resolver(route);
    IF result NOT IN ('pending','review','success') OR result IS NULL THEN RAISE EXCEPTION 'invalid alternative work result' USING ERRCODE='22023'; END IF;
    UPDATE meton_inbox.alternative_cash_jobs SET state=result,token=NULL,next_at=CASE WHEN result IN ('review','success') THEN 'infinity'::timestamptz ELSE clock_timestamp()+interval '15 seconds' END
        WHERE refund=ref AND token=lease AND state='working' AND EXISTS(SELECT FROM meton_inbox.refund_alternative_decisions d
            WHERE d.refund=ref AND (d.proposal#>>'{envelope,scope,deployment}',d.proposal#>>'{envelope,scope,source}',
                d.proposal#>>'{envelope,scope,channel}',d.proposal#>>'{envelope,scope,cashEnvironment}',d.proposal#>>'{envelope,scope,merchant}',d.proposal#>>'{envelope,scope,app}')=
                (route->>'deployment',route->>'source',route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app'));
    RETURN FOUND;
END $$;

/** 许可与实际出站之间不能遗失新事实。调用者已持原现金锁；快照含未归一化回执，不能只比较可能尚未刷新的投影。 */
CREATE FUNCTION meton_inbox.alternative_cash_validation(d meton_inbox.refund_alternative_decisions) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE original bytea:=meton_inbox.cash_original_identity(d.proposal->'envelope'); facts jsonb;b meton_inbox.refund_wire_bindings;
BEGIN
    SELECT * INTO STRICT b FROM meton_inbox.refund_wire_bindings WHERE refund=d.refund;
    SELECT jsonb_build_array(
        (SELECT jsonb_agg(jsonb_build_array(v.operation,encode(v.digest,'hex')) ORDER BY v.operation) FROM meton_inbox.refund_payer_reviews v WHERE v.refund=d.refund),
        (SELECT jsonb_agg(jsonb_build_array(x.refund,x.envelope,meton_inbox.original_refund_wire_risk(x.envelope),
            (SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM meton_inbox.refund_resolution_samples(x) s),
            (SELECT to_jsonb(g) FROM meton_inbox.refund_gate_decisions g WHERE g.refund=x.refund),
            (SELECT jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text) FROM meton_inbox.refund_sender_retirements r WHERE r.refund=x.refund)) ORDER BY x.refund)
            FROM meton_inbox.refund_wire_bindings x WHERE meton_inbox.cash_original_identity(x.envelope)=original),
        meton_inbox.all_original_cash_return_exposure(b)-'pendingCommit',
        (SELECT jsonb_agg(jsonb_build_array(x.refund,x.proposal,x.choice,x.ticket) ORDER BY x.refund)
            FROM meton_inbox.refund_alternative_decisions x WHERE meton_inbox.cash_original_identity(x.proposal->'envelope')=original)
    ) INTO facts;
    RETURN encode(sha256(convert_to(facts::text,'UTF8')),'hex');
END $$;

/** 发送前重新核验当前付款人、收款归属、原路状态和累计现金；已有派发声明只能得到查询许可。 */
CREATE FUNCTION meton_inbox.prepare_alternative_cash(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);d meton_inbox.refund_alternative_decisions;b meton_inbox.refund_wire_bindings;
    check_result jsonb;exposure jsonb;reserved numeric;scope jsonb;f jsonb;mode text;other meton_inbox.refund_wire_bindings;
BEGIN
    check_result:=meton_inbox.original_alternative_decision(route,ref);
    IF check_result->>'state' IS DISTINCT FROM 'decision_proved' OR check_result#>>'{facts,choice}' IS DISTINCT FROM 'reserved' THEN RETURN jsonb_build_object('state','unavailable'); END IF;
    SELECT * INTO STRICT d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref;
    SELECT * INTO STRICT b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    mode:='query';
    IF NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=ref) THEN
        check_result:=meton_inbox.original_refund_aftercare_result(route,ref);
        IF check_result->>'state'='recorded' THEN RETURN check_result; END IF;
        IF check_result->>'state' IS DISTINCT FROM 'verification_proved' OR
            (check_result#>>'{facts,verification,payerState}',check_result#>>'{facts,verification,channelState}') IS DISTINCT FROM ('verified','closed_unpaid') OR
            NOT EXISTS(SELECT FROM meton_inbox.refund_payer_reviews v WHERE v.refund=ref AND v.facts->>'outcome'='matched'
                AND v.facts->>'beneficiaryHash'=d.proposal#>>'{payment,beneficiaryHash}') THEN RETURN jsonb_build_object('state','review'); END IF;
        FOR other IN SELECT * FROM meton_inbox.refund_wire_bindings x WHERE x.refund<>ref AND meton_inbox.cash_original_identity(x.envelope)=meton_inbox.cash_original_identity(b.envelope) LOOP
            check_result:=meton_inbox.original_refund_cash_result(route,other.refund);
            IF check_result->>'state'='recorded' THEN RETURN check_result; END IF;
            IF (check_result->>'state' IN ('success_proved','closed_observed')) IS NOT TRUE THEN RETURN jsonb_build_object('state','review'); END IF;
        END LOOP;
        exposure:=meton_inbox.all_original_cash_return_exposure(b);
        SELECT coalesce(sum((x.proposal#>>'{payment,fen}')::numeric),0) INTO reserved FROM meton_inbox.refund_alternative_decisions x
            WHERE x.choice='reserved' AND meton_inbox.cash_original_identity(x.proposal->'envelope')=meton_inbox.cash_original_identity(b.envelope);
        IF exposure->>'payerCapFen' IS NULL OR (exposure->>'pendingCommit')::boolean OR
            ((exposure->>'ambiguousExternalEvents')::bigint=0 AND (exposure->>'ambiguousRefundEvents')::bigint=0 AND
            (exposure->>'knownReturnedFen')::numeric+reserved<=(exposure->>'payerCapFen')::numeric) IS NOT TRUE THEN RETURN jsonb_build_object('state','review'); END IF;
        mode:='send';
    END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    f:=jsonb_build_object('format',1,'scope',scope,'proposal',d.proposal,'ticket',d.ticket,'mode',mode,
        'validationHash',CASE WHEN mode='send' THEN meton_inbox.alternative_cash_validation(d) END,'validUntil',clock_timestamp()+interval '20 seconds');
    RETURN jsonb_build_object('state','ready','facts',f,'mac',encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.io.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 发送身份只能使用当前协调签出的原目标；其自身没有审核或资金结清权。 */
CREATE FUNCTION meton_inbox.require_alternative_cash_sender(proof jsonb) RETURNS meton_inbox.refund_alternative_decisions
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE f jsonb:=proof->'facts';a meton_inbox.refund_gate_authorities:=meton_inbox.require_original_wire_sender(f->'scope');d meton_inbox.refund_alternative_decisions;
BEGIN
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=(f#>>'{proposal,refund}')::uuid;
    IF proof->>'state' IS DISTINCT FROM 'ready' OR f->'proposal' IS DISTINCT FROM d.proposal OR d.choice IS DISTINCT FROM 'reserved'
        OR d.ticket::text IS DISTINCT FROM f->>'ticket' OR ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.io.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified alternative cash permission' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(d.proposal#>'{envelope,scope}',d.proposal#>>'{envelope,cash,order}',d.proposal#>>'{envelope,cash,transaction}');
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.refund.alternative.io.v1/'||d.refund::text,0));
    RETURN d;
END $$;

CREATE FUNCTION meton_inbox.begin_alternative_cash(proof jsonb,source_proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_alternative_decisions:=meton_inbox.require_alternative_cash_sender(proof);
    f jsonb:=proof->'facts';s jsonb:=source_proof->'facts';a meton_inbox.refund_gate_authorities:=meton_inbox.require_original_wire_sender(f->'scope');secret bytea;
BEGIN
    IF f->>'mode' IS DISTINCT FROM 'send' OR source_proof->>'state' IS DISTINCT FROM 'source_ready' OR s->'scope' IS DISTINCT FROM f->'scope' OR
        s->'proposal' IS DISTINCT FROM d.proposal OR s->>'ticket' IS DISTINCT FROM d.ticket::text OR
        ((s->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        source_proof->>'mac' IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.io-source.v1',s)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'alternative source share not proved' USING ERRCODE='42501'; END IF;
    -- 协调事务已经结束；必须在重新取得的原现金锁内复算，而非假定批准之后没有新增回执。
    IF f->>'validationHash' IS DISTINCT FROM meton_inbox.alternative_cash_validation(d) THEN RETURN NULL; END IF;
    secret:=uuid_send(gen_random_uuid())||uuid_send(gen_random_uuid());
    INSERT INTO meton_inbox.alternative_cash_attempts(refund,scope,secret_hash,valid_until)
        VALUES(d.refund,f->'scope',sha256(secret),least((f->>'validUntil')::timestamptz,(s->>'validUntil')::timestamptz)) ON CONFLICT DO NOTHING;
    RETURN CASE WHEN FOUND THEN encode(secret,'hex') END;
END $$;
CREATE FUNCTION meton_inbox.hold_alternative_cash(proof jsonb,secret text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_alternative_decisions:=meton_inbox.require_alternative_cash_sender(proof);
BEGIN
    IF secret IS NULL OR secret !~ '^[0-9a-f]{64}$' OR proof#>>'{facts,mode}' IS DISTINCT FROM 'send' OR
        proof#>>'{facts,validationHash}' IS DISTINCT FROM meton_inbox.alternative_cash_validation(d) THEN RETURN false; END IF;
    INSERT INTO meton_inbox.alternative_cash_uses(refund) SELECT x.refund FROM meton_inbox.alternative_cash_attempts x
        WHERE x.refund=d.refund AND x.scope=proof#>'{facts,scope}' AND x.secret_hash=sha256(decode(secret,'hex')) AND x.valid_until>clock_timestamp()
            AND x.recorded_xid<>pg_current_xact_id() ON CONFLICT DO NOTHING;
    RETURN FOUND;
END $$;

/** 保存已经验签且与原替代目标完全一致的事实。POST 成功也只作观察，现金成功只取查询凭证。 */
CREATE FUNCTION meton_inbox.record_alternative_cash(proof jsonb,verb text,fact jsonb,digest bytea,key_reference text,evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_alternative_decisions:=meton_inbox.require_alternative_cash_sender(proof);saved meton_inbox.alternative_cash_observations;other uuid;
BEGIN
    IF verb IS NULL OR verb NOT IN ('POST','GET') OR (verb='POST') IS DISTINCT FROM (proof#>>'{facts,mode}'='send') OR
        fact->'payment' IS DISTINCT FROM d.proposal->'payment' OR
        (fact->>'state' IN ('pending','succeeded','failed','not_found') AND (fact->>'state'<>'succeeded' OR fact->>'transaction'~'^[A-Za-z0-9_.:-]{1,120}$')
        AND octet_length(digest)=32 AND length(key_reference) BETWEEN 1 AND 120 AND octet_length(evidence) BETWEEN 29 AND 1572864) IS NOT TRUE OR
        NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=d.refund) THEN
        RAISE EXCEPTION 'alternative cash observation differs' USING ERRCODE='42501'; END IF;
    IF fact->>'state'='succeeded' THEN PERFORM pg_advisory_xact_lock(hashtextextended('meton.alternative.cash-id.v1/'||
        jsonb_build_array(fact#>>'{payment,rail}',fact#>>'{payment,environment}',fact#>>'{payment,merchant}',fact->>'transaction')::text,0)); END IF;
    SELECT * INTO saved FROM meton_inbox.alternative_cash_observations o WHERE (o.refund,o.verb,o.digest)=(d.refund,record_alternative_cash.verb,record_alternative_cash.digest);
    IF FOUND THEN
        IF saved.facts IS DISTINCT FROM fact THEN RAISE EXCEPTION 'alternative evidence identity reused' USING ERRCODE='22023'; END IF;
        RETURN 'recorded';
    END IF;
    INSERT INTO meton_inbox.alternative_cash_observations VALUES(d.refund,verb,digest,fact,key_reference,evidence);
    PERFORM meton_inbox.wake_refund_settlement(d.refund);
    IF verb='GET' AND fact->>'state'='succeeded' THEN
        FOR other IN SELECT DISTINCT o.refund FROM meton_inbox.alternative_cash_observations o WHERE o.refund<>d.refund AND o.verb='GET'
            AND (o.facts#>>'{payment,rail}',o.facts#>>'{payment,environment}',o.facts#>>'{payment,merchant}',o.facts->>'transaction')=
                (fact#>>'{payment,rail}',fact#>>'{payment,environment}',fact#>>'{payment,merchant}',fact->>'transaction')
        LOOP PERFORM meton_inbox.wake_refund_settlement(other); END LOOP;
    END IF;
    RETURN 'recorded';
END $$;

/** 原现金与替代现金共同保留；独立事实提交后才签结清证明，冲突不能靠选择其中一条来抹平。 */
CREATE FUNCTION meton_inbox.alternative_cash_result(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);d meton_inbox.refund_alternative_decisions;
    original jsonb;x meton_inbox.alternative_cash_observations;candidate jsonb;positive meton_inbox.alternative_cash_positive;
    n bigint;fresh boolean;conflict boolean:=false;hash bytea;scope jsonb;f jsonb;review_hash text;
BEGIN
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice='reserved';
    IF NOT FOUND THEN RETURN NULL; END IF;
    PERFORM meton_inbox.original_alternative_decision(route,ref);
    original:=meton_inbox.original_refund_cash_result(route,ref);
    IF original->>'state'='recorded' THEN RETURN original; END IF;
    FOR x IN SELECT * FROM meton_inbox.alternative_cash_observations WHERE refund=ref LOOP
        IF x.verb='GET' AND x.facts->>'state'='succeeded' THEN
            candidate:=jsonb_build_object('payment',x.facts->'payment','transaction',x.facts->'transaction');hash:=sha256(convert_to(candidate::text,'UTF8'));
            INSERT INTO meton_inbox.alternative_cash_positive(refund,economic_hash,cash) VALUES(ref,hash,candidate) ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
    SELECT count(*),coalesce(bool_or(recorded_xid=pg_current_xact_id()),false) INTO n,fresh FROM meton_inbox.alternative_cash_positive WHERE refund=ref;
    conflict:=n>1 OR coalesce(original->>'state' IN ('success_proved','review'),true) OR n>0 AND EXISTS(
        SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref AND facts->>'state'='failed');
    IF fresh THEN RETURN jsonb_build_object('state','recorded'); END IF;
    IF n=0 AND NOT conflict THEN RETURN jsonb_build_object('state','alternative_pending'); END IF;
    IF n=1 THEN
        SELECT * INTO STRICT positive FROM meton_inbox.alternative_cash_positive WHERE refund=ref;
        PERFORM pg_advisory_xact_lock(hashtextextended('meton.alternative.cash-id.v1/'||jsonb_build_array(
            positive.cash#>>'{payment,rail}',positive.cash#>>'{payment,environment}',positive.cash#>>'{payment,merchant}',positive.cash->>'transaction')::text,0));
        conflict:=conflict OR EXISTS(SELECT FROM meton_inbox.alternative_cash_observations o WHERE o.refund<>ref AND o.verb='GET' AND o.facts->>'state'='succeeded'
            AND (o.facts#>>'{payment,rail}',o.facts#>>'{payment,environment}',o.facts#>>'{payment,merchant}',o.facts->>'transaction')=
                (positive.cash#>>'{payment,rail}',positive.cash#>>'{payment,environment}',positive.cash#>>'{payment,merchant}',positive.cash->>'transaction'));
    END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    SELECT encode(sha256(convert_to(coalesce(string_agg(encode(digest,'hex'),',' ORDER BY verb,digest),'')||'/'||
        jsonb_build_array(original->'state',(original->'facts')-ARRAY['scope','validUntil'],conflict)::text,'UTF8')),'hex') INTO review_hash
        FROM meton_inbox.alternative_cash_observations WHERE refund=ref;
    f:=jsonb_build_object('format',1,'state',CASE WHEN conflict THEN 'alternative_review' ELSE 'alternative_success' END,
        'scope',scope,'proposal',d.proposal,'cash',positive.cash,'economicHash',encode(positive.economic_hash,'hex'),
        'reviewHash',review_hash,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state',CASE WHEN conflict THEN 'alternative_review' ELSE 'alternative_success' END,'facts',f,'mac',
        encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.cash.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;
REVOKE ALL ON FUNCTION meton_inbox.schedule_alternative_cash(),meton_inbox.claim_alternative_cash(jsonb),meton_inbox.finish_alternative_cash(jsonb,uuid,uuid,text),
    meton_inbox.alternative_cash_validation(meton_inbox.refund_alternative_decisions),meton_inbox.prepare_alternative_cash(jsonb,uuid),meton_inbox.require_alternative_cash_sender(jsonb),meton_inbox.begin_alternative_cash(jsonb,jsonb),
    meton_inbox.hold_alternative_cash(jsonb,text),meton_inbox.record_alternative_cash(jsonb,text,jsonb,bytea,text,bytea),meton_inbox.alternative_cash_result(jsonb,uuid) FROM PUBLIC;
