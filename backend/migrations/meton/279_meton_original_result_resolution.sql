-- 首次观察、核对证据和选用结论分别保留。原调用和原费用权威不变。
CREATE FUNCTION meton_ledger.validate_text_observation(p_spec jsonb,p_observation jsonb)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE u jsonb; ready boolean; terminal text;
BEGIN
    IF p_observation IS NULL OR jsonb_typeof(p_observation)<>'object' OR
        (p_observation ?& ARRAY['format_version','protocol','execution','terminal','response_id','usage','fee_ready','read_end','body_sha256']) IS NOT TRUE OR
        (SELECT count(*) FROM jsonb_object_keys(p_observation))<>9 OR
        jsonb_typeof(p_observation->'format_version') IS DISTINCT FROM 'number' OR p_observation->>'format_version' IS DISTINCT FROM '1' OR
        jsonb_typeof(p_observation->'fee_ready') IS DISTINCT FROM 'boolean' OR
        EXISTS(SELECT FROM jsonb_each(p_observation) WHERE key IN ('protocol','execution','terminal','response_id','read_end','body_sha256') AND jsonb_typeof(value)<>'string') OR
        p_observation->>'protocol' IS DISTINCT FROM p_spec->>'wire_protocol' OR
        p_observation->>'execution' NOT IN ('unknown','completed','failed') OR
        p_observation->>'read_end' NOT IN ('eof','closed','read_error') OR
        p_observation->>'body_sha256' !~ '^[a-f0-9]{64}$' OR
        p_observation->>'response_id' !~ '^[A-Za-z0-9_.:-]*$' OR length(p_observation->>'response_id')>256 THEN
        RAISE EXCEPTION 'invalid execution observation' USING ERRCODE='22023'; END IF;
    ready:=(p_observation->>'fee_ready')::boolean;
    terminal:=p_observation->>'terminal';
    IF terminal<>'' THEN
        IF (p_observation->>'protocol'='responses' AND terminal NOT IN ('response.completed','response.failed','response.incomplete','response.cancelled')) OR
           (p_observation->>'protocol'='chat_completions' AND terminal NOT IN ('chat.stop','chat.tool_calls','chat.function_call','chat.length','chat.content_filter')) OR
           (p_observation->>'execution' IS DISTINCT FROM CASE WHEN terminal IN ('response.completed','chat.stop','chat.tool_calls','chat.function_call') THEN 'completed' ELSE 'failed' END) THEN
            RAISE EXCEPTION 'conflicting execution terminal' USING ERRCODE='22023'; END IF;
    ELSIF p_observation->>'execution'='completed' OR ready THEN
        RAISE EXCEPTION 'terminal proof missing' USING ERRCODE='22023';
    END IF;
    u:=p_observation->'usage';
    IF jsonb_typeof(u)<>'null' THEN
        IF jsonb_typeof(u)<>'object' OR (u ?& ARRAY['input','output','cached']) IS NOT TRUE OR (SELECT count(*) FROM jsonb_object_keys(u))<>3 OR
            jsonb_typeof(u->'input') IS DISTINCT FROM 'number' OR jsonb_typeof(u->'output') IS DISTINCT FROM 'number' OR
            u->>'input' !~ '^(0|[1-9][0-9]{0,8})$' OR u->>'output' !~ '^(0|[1-9][0-9]{0,8})$' OR
            (u->>'input')::bigint>100000000 OR (u->>'output')::bigint>100000000 OR
            (jsonb_typeof(u->'cached')<>'null' AND (jsonb_typeof(u->'cached') IS DISTINCT FROM 'number' OR
                u->>'cached' !~ '^(0|[1-9][0-9]{0,8})$' OR (u->>'cached')::bigint>(u->>'input')::bigint)) THEN
            RAISE EXCEPTION 'invalid explicit execution usage' USING ERRCODE='22023'; END IF;
    END IF;
    IF ready AND (jsonb_typeof(u)<>'object' OR jsonb_typeof(u->'cached') IS DISTINCT FROM 'number' OR p_observation->>'response_id'='') THEN
        RAISE EXCEPTION 'complete explicit usage required' USING ERRCODE='22023'; END IF;
END $$;

-- 普通收尾和运营核对共用原冻结价格及取整规则，不另建费用算法。
CREATE FUNCTION meton_ledger.execution_observation_amount(h meton_ledger.text_hold_receipt,p_observation jsonb)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE price meton_ledger.text_prices%ROWTYPE; u jsonb:=p_observation->'usage';
BEGIN
    SELECT * INTO STRICT price FROM meton_ledger.text_prices WHERE (environment,source,protocol,model,version)=
        (h.environment,h.source,h.protocol,h.model,h.price_version);
    RETURN ceil((((u->>'input')::bigint-(u->>'cached')::bigint)*price.input_per_million+
        (u->>'cached')::bigint*price.cached_per_million+(u->>'output')::bigint*price.output_per_million)*price.multiplier*100)*0.00000001;
END $$;

CREATE FUNCTION meton_ledger.post_execution_observation(h meton_ledger.text_hold_receipt,p_observation jsonb,p_proof uuid)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE amount numeric(20,8);
BEGIN
    amount:=meton_ledger.execution_observation_amount(h,p_observation);
    PERFORM meton_ledger.post_text_fee(h.environment,h.source,h.epoch_at_accept,h.meton_user,h.account,h.source_marker,h.caller,h.operation_id,
        h.request_id,h.request_id,p_proof,1,h.price_version,h.unit,amount::text,NULL,NULL,NULL);
    PERFORM meton_ledger.end_text_fees(h.environment,h.source,h.epoch_at_accept,h.meton_user,h.account,h.source_marker,h.caller,h.operation_id,
        h.request_id,p_proof,ARRAY[p_proof]);
END $$;

CREATE OR REPLACE FUNCTION meton_ledger.complete_execution_text(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_hash text,p_spec jsonb,p_observation jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; old meton_ledger.text_completions%ROWTYPE; proof uuid;
BEGIN
    -- 不再要求用户 Key 仍然有效：已执行的原请求仍须记实耗。恢复代次与原归属继续由来源锁复验。
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF NOT EXISTS(SELECT FROM meton_ledger.text_executions e JOIN meton_ledger.text_transports t USING(request_id)
        WHERE e.request_id=p_request AND e.spec=p_spec AND t.context_hash=p_hash) THEN
        RAISE EXCEPTION 'different original execution evidence' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.validate_text_observation(p_spec,p_observation);
    SELECT * INTO old FROM meton_ledger.text_completions WHERE request_id=p_request;
    IF FOUND THEN
        IF old.observation IS DISTINCT FROM p_observation THEN
            RAISE EXCEPTION 'original completion conflict' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.find_execution_result(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    END IF;
    INSERT INTO meton_ledger.text_completions(request_id,observation) VALUES(p_request,p_observation) RETURNING event_id INTO proof;
    IF (p_observation->>'fee_ready')::boolean THEN
        PERFORM meton_ledger.post_execution_observation(h,p_observation,proof);
    END IF;
    RETURN meton_ledger.find_execution_result(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
END $$;

ALTER TABLE meton_ledger.text_completions ADD CONSTRAINT completion_original_pair UNIQUE(request_id,event_id);
CREATE TABLE meton_ledger.text_result_proofs (
    evidence_id uuid PRIMARY KEY CHECK(evidence_id<>'00000000-0000-0000-0000-000000000000'),
    request_id uuid NOT NULL, prior_event uuid NOT NULL, context_hash text NOT NULL CHECK(context_hash~'^[a-f0-9]{64}$'),
    epoch bigint NOT NULL CHECK(epoch>0), observation jsonb NOT NULL, observer name NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(request_id,evidence_id),
    FOREIGN KEY(request_id,prior_event) REFERENCES meton_ledger.text_completions(request_id,event_id) ON DELETE RESTRICT
);
CREATE TABLE meton_ledger.text_result_resolutions (
    request_id uuid PRIMARY KEY, evidence_id uuid NOT NULL UNIQUE,
    event_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    case_id uuid NOT NULL CHECK(case_id<>'00000000-0000-0000-0000-000000000000'),
    attempt_id uuid NOT NULL CHECK(attempt_id<>'00000000-0000-0000-0000-000000000000'),
    approval_digest text NOT NULL CHECK(approval_digest~'^[a-f0-9]{64}$'), executor name NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(request_id,evidence_id) REFERENCES meton_ledger.text_result_proofs(request_id,evidence_id) ON DELETE RESTRICT
);
DO $migration$
DECLARE relation text;
BEGIN
    FOREACH relation IN ARRAY ARRAY['text_result_proofs','text_result_resolutions'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',relation);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',relation);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',relation);
    END LOOP;
END $migration$;

-- 两份观察只能属于已经持久保存的同一响应；缺原响应号不能靠运营补猜。
CREATE FUNCTION meton_ledger.check_text_resolution_observation(p_request uuid,p_prior uuid,p_hash text,p_spec jsonb,p_observation jsonb)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE prior jsonb;
BEGIN
    SELECT c.observation INTO prior FROM meton_ledger.text_completions c JOIN meton_ledger.text_transports t USING(request_id)
        JOIN meton_ledger.text_executions e USING(request_id)
        WHERE c.request_id=p_request AND c.event_id=p_prior AND t.context_hash=p_hash AND e.spec=p_spec;
    IF NOT FOUND OR prior->>'fee_ready' IS DISTINCT FROM 'false' OR prior->>'response_id'='' THEN
        RAISE EXCEPTION 'original unresolved response evidence required' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.validate_text_observation(p_spec,p_observation);
    IF p_observation->>'response_id' IS DISTINCT FROM prior->>'response_id' OR
        p_observation->>'fee_ready' IS DISTINCT FROM 'true' OR p_observation->>'execution'='unknown' OR
        p_observation->>'read_end'<>'eof' OR
        (prior->>'terminal'<>'' AND (p_observation->>'terminal',p_observation->>'execution') IS DISTINCT FROM
                                   (prior->>'terminal',prior->>'execution')) THEN
        RAISE EXCEPTION 'incomplete or conflicting original result proof' USING ERRCODE='22023'; END IF;
END $$;

CREATE FUNCTION meton_ledger.record_text_result_proof(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_prior uuid,p_hash text,p_spec jsonb,p_evidence uuid,p_observation jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; old meton_ledger.text_result_proofs%ROWTYPE;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF has_function_privilege(session_user,'meton_ledger.apply_text_result_proof(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,text)','EXECUTE') THEN
        RAISE EXCEPTION 'observer cannot also execute resolution' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.check_text_resolution_observation(p_request,p_prior,p_hash,p_spec,p_observation);
    SELECT * INTO old FROM meton_ledger.text_result_proofs WHERE evidence_id=p_evidence;
    IF FOUND THEN
        IF (old.request_id,old.prior_event,old.context_hash,old.epoch,old.observation) IS DISTINCT FROM
           (p_request,p_prior,p_hash,p_epoch,p_observation) THEN
            RAISE EXCEPTION 'different original result evidence' USING ERRCODE='23505'; END IF;
        RETURN to_jsonb(old);
    END IF;
    INSERT INTO meton_ledger.text_result_proofs(evidence_id,request_id,prior_event,context_hash,epoch,observation,observer)
        VALUES(p_evidence,p_request,p_prior,p_hash,p_epoch,p_observation,session_user) RETURNING * INTO old;
    RETURN to_jsonb(old);
END $$;

CREATE FUNCTION meton_ledger.find_text_result_proof(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_evidence uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt;
BEGIN
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN
        RAISE EXCEPTION 'original execution required' USING ERRCODE='55000'; END IF;
    RETURN (SELECT to_jsonb(p) FROM meton_ledger.text_result_proofs p WHERE request_id=p_request AND evidence_id=p_evidence);
END $$;

CREATE FUNCTION meton_ledger.find_text_resolution(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; r meton_ledger.text_result_resolutions%ROWTYPE; p meton_ledger.text_result_proofs%ROWTYPE;
    posting jsonb; ending jsonb; origin jsonb;
BEGIN
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN
        RAISE EXCEPTION 'original execution required' USING ERRCODE='55000'; END IF;
    SELECT * INTO r FROM meton_ledger.text_result_resolutions WHERE request_id=p_request;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO STRICT p FROM meton_ledger.text_result_proofs WHERE evidence_id=r.evidence_id AND request_id=p_request;
    posting:=meton_ledger.find_text_posting(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_request,r.event_id);
    ending:=meton_ledger.find_text_ending(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF posting IS NULL OR ending IS NULL OR ending->>'proof' IS DISTINCT FROM r.event_id::text OR
        ending->'final_events' IS DISTINCT FROM to_jsonb(ARRAY[r.event_id]) THEN
        RAISE EXCEPTION 'resolution accounting requires reconciliation' USING ERRCODE='23514'; END IF;
    origin:=jsonb_build_object('environment',p_env,'source',p_source,'user',p_user,'account',p_account,
        'source_marker',p_marker,'caller',p_caller,'operation_id',p_operation,'source_request_id',p_request);
    RETURN jsonb_build_object('version',1,'origin',origin,'prior_event',p.prior_event,'evidence_id',p.evidence_id,
        'case_id',r.case_id,'attempt_id',r.attempt_id,'approval_digest',r.approval_digest,
        'result',jsonb_build_object('version',1,'origin',origin,'event_id',r.event_id,'observation',p.observation,'posting',posting,'ending',ending));
END $$;

CREATE FUNCTION meton_ledger.apply_text_result_proof(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_evidence uuid,p_case uuid,p_attempt uuid,p_approval text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; proof meton_ledger.text_result_proofs%ROWTYPE; chosen meton_ledger.text_result_resolutions%ROWTYPE; spec jsonb;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF has_function_privilege(session_user,'meton_ledger.record_text_result_proof(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,text,jsonb,uuid,jsonb)','EXECUTE') THEN
        RAISE EXCEPTION 'executor cannot also produce evidence' USING ERRCODE='42501'; END IF;
    SELECT * INTO proof FROM meton_ledger.text_result_proofs WHERE evidence_id=p_evidence AND request_id=p_request AND epoch=p_epoch;
    IF NOT FOUND OR proof.observer=session_user THEN
        RAISE EXCEPTION 'independent original result proof required' USING ERRCODE='42501'; END IF;
    SELECT e.spec INTO STRICT spec FROM meton_ledger.text_executions e WHERE request_id=p_request;
    PERFORM meton_ledger.check_text_resolution_observation(p_request,proof.prior_event,proof.context_hash,spec,proof.observation);
    SELECT * INTO chosen FROM meton_ledger.text_result_resolutions WHERE request_id=p_request;
    IF FOUND THEN
        IF (chosen.evidence_id,chosen.case_id,chosen.attempt_id,chosen.approval_digest) IS DISTINCT FROM (p_evidence,p_case,p_attempt,p_approval) THEN
            RAISE EXCEPTION 'different resolution execution' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.find_text_resolution(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    END IF;
    IF EXISTS(SELECT FROM meton_ledger.text_result_proofs p WHERE p.request_id=p_request AND (p.observation-'body_sha256') IS DISTINCT FROM (proof.observation-'body_sha256')) THEN
        RAISE EXCEPTION 'conflicting source proofs require review' USING ERRCODE='55000'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.text_fee_reports WHERE request_id=p_request) OR
       EXISTS(SELECT FROM meton_ledger.text_fee_endings WHERE request_id=p_request) THEN
        RAISE EXCEPTION 'existing original fee requires separate reconciliation' USING ERRCODE='55000'; END IF;
    INSERT INTO meton_ledger.text_result_resolutions(request_id,evidence_id,case_id,attempt_id,approval_digest,executor)
        VALUES(p_request,p_evidence,p_case,p_attempt,p_approval,session_user) RETURNING * INTO chosen;
    PERFORM meton_ledger.post_execution_observation(h,proof.observation,chosen.event_id);
    RETURN meton_ledger.find_text_resolution(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
END $$;

-- 还原或迁移不能只放回一条“结案”记录。其指定原观察、原终局金额和结清清单必须齐备。
CREATE FUNCTION meton_ledger.check_text_resolution_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p meton_ledger.text_result_proofs%ROWTYPE; h meton_ledger.text_hold_receipt; spec jsonb;
BEGIN
    SELECT * INTO STRICT p FROM meton_ledger.text_result_proofs WHERE evidence_id=NEW.evidence_id AND request_id=NEW.request_id;
    -- 约束验证已发生事实；关闭期间还原完整材料也必须能提交，不能借此要求重新开放在线写权。
    -- 真正执行仍先经过 lock_dispatched_fee；原受理代次和冻结价格在此按持久记录核对。
    SELECT r.environment,r.source,r.protocol,r.model,r.price_version,r.epoch_at_accept
        INTO STRICT h.environment,h.source,h.protocol,h.model,h.price_version,h.epoch_at_accept
        FROM meton_ledger.text_requests r WHERE r.request_id=NEW.request_id AND r.epoch_at_accept=p.epoch;
    SELECT e.spec INTO STRICT spec FROM meton_ledger.text_executions e WHERE request_id=NEW.request_id;
    PERFORM meton_ledger.check_text_resolution_observation(NEW.request_id,p.prior_event,p.context_hash,spec,p.observation);
    IF p.observer=NEW.executor OR NOT EXISTS(SELECT FROM meton_ledger.text_fee_reports f JOIN meton_ledger.text_postings x ON x.report_event=f.event_id
        JOIN meton_ledger.text_fee_endings e ON e.request_id=f.request_id
        WHERE f.request_id=NEW.request_id AND f.item_id=NEW.request_id AND f.event_id=NEW.event_id AND f.revision=1 AND f.state='final'
          AND f.previous_event IS NULL AND f.amount=meton_ledger.execution_observation_amount(h,p.observation)
          AND e.proof=NEW.event_id AND e.final_events=ARRAY[NEW.event_id]) THEN
        RAISE EXCEPTION 'resolution lacks complete original accounting' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER complete_text_resolution AFTER INSERT ON meton_ledger.text_result_resolutions DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_text_resolution_commit();
ALTER TABLE meton_ledger.text_result_resolutions ENABLE ALWAYS TRIGGER complete_text_resolution;

-- 原创建和原调用唯一定位终局；查询角色不接收调用方自报的来源请求号或费用事件号。
CREATE OR REPLACE FUNCTION meton_ledger.read_text_result(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_caller text,p_operation uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admission jsonb; original jsonb; fee jsonb; result jsonb; o jsonb;
BEGIN
    admission:=meton_ledger.read_text_reference(p_env,p_source,p_epoch,p_creation,p_caller,p_operation,NULL);
    IF admission IS NULL THEN RETURN NULL; END IF;
    o:=admission->'origin';
    original:=meton_ledger.find_text_resolution(p_env,p_source,p_epoch,(o->>'user')::uuid,(o->>'account')::uuid,
        (o->>'source_marker')::uuid,p_caller,p_operation,(o->>'source_request_id')::uuid)->'result';
    IF original IS NULL THEN
    original:=meton_ledger.find_execution_result(p_env,p_source,p_epoch,(o->>'user')::uuid,(o->>'account')::uuid,
        (o->>'source_marker')::uuid,p_caller,p_operation,(o->>'source_request_id')::uuid);
    END IF;
    IF original IS NOT NULL THEN
        IF original->'posting' IS NOT NULL AND original->'posting'<>'null'::jsonb THEN
            fee:=jsonb_build_object('reference',original->'posting'->'report',
                'funded',original->'posting'->'funded','uncovered',original->'posting'->'uncovered');
        END IF;
        -- 仅投影有界元数据。正文、响应 ID、正文摘要和各个资金来源分配不进入跨服务回执。
        result:=jsonb_build_object('observation_id',original->'event_id',
            'execution',original->'observation'->'execution','usage',original->'observation'->'usage','fee',fee);
        IF EXISTS(SELECT FROM meton_ledger.text_result_proofs a JOIN meton_ledger.text_result_proofs b USING(request_id)
            WHERE a.request_id=(o->>'source_request_id')::uuid AND (a.observation-'body_sha256') IS DISTINCT FROM (b.observation-'body_sha256')) THEN
            result:=jsonb_set(result,'{execution}','"unknown"'::jsonb);
        END IF;
    END IF;
    RETURN jsonb_build_object('version',1,'admission',admission,'result',result);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_text_result(text,text,bigint,uuid,text,uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION meton_ledger.validate_text_observation(jsonb,jsonb),
    meton_ledger.execution_observation_amount(meton_ledger.text_hold_receipt,jsonb),
    meton_ledger.post_execution_observation(meton_ledger.text_hold_receipt,jsonb,uuid),
    meton_ledger.check_text_resolution_observation(uuid,uuid,text,jsonb,jsonb),
    meton_ledger.record_text_result_proof(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,text,jsonb,uuid,jsonb),
    meton_ledger.apply_text_result_proof(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,text),
    meton_ledger.find_text_resolution(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid),
    meton_ledger.find_text_result_proof(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid),
    meton_ledger.check_text_resolution_commit() FROM PUBLIC;
