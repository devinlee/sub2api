-- 原受理及证明登记代次保持，当前写权显式传递；复用 286 的原恢复和旧 Key 撤销核验。
CREATE FUNCTION meton_ledger.post_execution_observation(h meton_ledger.text_hold_receipt,p_observation jsonb,p_proof uuid,p_epoch bigint)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE amount numeric(20,8);
BEGIN
    PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
    amount:=meton_ledger.execution_observation_amount(h,p_observation);
    PERFORM meton_ledger.post_text_fee(h.environment,h.source,p_epoch,h.meton_user,h.account,h.source_marker,h.caller,h.operation_id,
        h.request_id,h.request_id,p_proof,1,h.price_version,h.unit,amount::text,NULL,NULL,NULL);
    PERFORM meton_ledger.end_text_fees(h.environment,h.source,p_epoch,h.meton_user,h.account,h.source_marker,h.caller,h.operation_id,
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
        PERFORM meton_ledger.post_execution_observation(h,p_observation,proof,p_epoch);
    END IF;
    RETURN meton_ledger.find_execution_result(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
END $$;

CREATE OR REPLACE FUNCTION meton_ledger.apply_text_result_proof(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
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
    PERFORM meton_ledger.post_execution_observation(h,proof.observation,chosen.event_id,p_epoch);
    RETURN meton_ledger.find_text_resolution(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
END $$;

CREATE OR REPLACE FUNCTION meton_ledger.check_text_resolution_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p meton_ledger.text_result_proofs%ROWTYPE; h meton_ledger.text_hold_receipt; spec jsonb;
BEGIN
    SELECT * INTO STRICT p FROM meton_ledger.text_result_proofs WHERE evidence_id=NEW.evidence_id AND request_id=NEW.request_id;
    -- 约束验证已发生事实；关闭期间还原完整材料也必须能提交，不能借此要求重新开放在线写权。
    -- 真正执行仍先经过 lock_dispatched_fee；原受理代次和冻结价格在此按持久记录核对。
    SELECT r.environment,r.source,r.protocol,r.model,r.price_version,r.epoch_at_accept
        INTO STRICT h.environment,h.source,h.protocol,h.model,h.price_version,h.epoch_at_accept
        FROM meton_ledger.text_requests r WHERE r.request_id=NEW.request_id;
    -- 只核历史事实的真实链路，不要求恢复期间开放全局写栅栏；原批准不会因此重新生效。
    IF NOT meton_ledger.correction_epoch_on_chain(NEW.request_id,p.epoch,p.epoch) THEN
        RAISE EXCEPTION 'resolution proof epoch not on original chain' USING ERRCODE='23514'; END IF;
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

CREATE OR REPLACE FUNCTION meton_ledger.find_provider_original(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; material jsonb; h meton_ledger.text_hold_receipt;
BEGIN
 SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
 IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN
  RAISE EXCEPTION 'original execution required' USING ERRCODE='55000'; END IF;
 PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
 result:=meton_ledger.find_execution_result(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
 IF result IS NULL OR (result->'observation'->>'fee_ready')::boolean THEN RETURN NULL; END IF;
 SELECT jsonb_build_object('version',1,'origin',result->'origin','prior_event',result->>'event_id','context_hash',t.context_hash,
  'spec',e.spec,'binding',b.binding,'observation',result->'observation') INTO material
 FROM meton_ledger.text_provider_bindings b JOIN meton_ledger.text_executions e USING(request_id)
 JOIN meton_ledger.text_transports t USING(request_id) JOIN meton_ledger.text_requests r USING(request_id)
 WHERE b.request_id=p_request;
 RETURN material;
END $$;

CREATE OR REPLACE FUNCTION meton_ledger.find_text_result_proof(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_evidence uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt;
BEGIN
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN
        RAISE EXCEPTION 'original execution required' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
    IF EXISTS(SELECT FROM meton_ledger.text_result_proofs p WHERE p.request_id=p_request AND p.evidence_id=p_evidence AND
        NOT meton_ledger.correction_epoch_on_chain(p_request,p.epoch,p_epoch)) THEN
        RAISE EXCEPTION 'original proof recovery chain required' USING ERRCODE='55000'; END IF;
    RETURN (SELECT to_jsonb(p) FROM meton_ledger.text_result_proofs p WHERE request_id=p_request AND evidence_id=p_evidence);
END $$;

CREATE OR REPLACE FUNCTION meton_ledger.find_text_resolution(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; r meton_ledger.text_result_resolutions%ROWTYPE; p meton_ledger.text_result_proofs%ROWTYPE;
    posting jsonb; ending jsonb; origin jsonb;
BEGIN
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN
        RAISE EXCEPTION 'original execution required' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
    SELECT * INTO r FROM meton_ledger.text_result_resolutions WHERE request_id=p_request;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO STRICT p FROM meton_ledger.text_result_proofs WHERE evidence_id=r.evidence_id AND request_id=p_request;
    IF NOT meton_ledger.correction_epoch_on_chain(p_request,p.epoch,p_epoch) THEN
        RAISE EXCEPTION 'original resolution recovery chain required' USING ERRCODE='55000'; END IF;
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

-- 不保留隐式拿原受理代次写账的私有入口，调用者权限未扩大。
DROP FUNCTION meton_ledger.post_execution_observation(meton_ledger.text_hold_receipt,jsonb,uuid);
REVOKE ALL ON FUNCTION meton_ledger.post_execution_observation(meton_ledger.text_hold_receipt,jsonb,uuid,bigint) FROM PUBLIC;
