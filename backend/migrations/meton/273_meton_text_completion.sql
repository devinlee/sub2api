-- 只接受原实际执行的有限响应事实。运行身份不能传入金额或更换价格，也不能调用裸结算例程。
CREATE TABLE meton_ledger.text_completions (
    request_id uuid PRIMARY KEY REFERENCES meton_ledger.text_executions ON DELETE RESTRICT,
    event_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    observation jsonb NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER immutable_text_completion BEFORE UPDATE OR DELETE ON meton_ledger.text_completions
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.text_completions ENABLE ALWAYS TRIGGER immutable_text_completion;

CREATE FUNCTION meton_ledger.find_execution_result(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; r meton_ledger.text_completions%ROWTYPE; posting jsonb; ending jsonb;
BEGIN
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN
        RAISE EXCEPTION 'original execution required' USING ERRCODE='55000'; END IF;
    SELECT * INTO r FROM meton_ledger.text_completions WHERE request_id=p_request;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF (r.observation->>'fee_ready')::boolean THEN
        posting:=meton_ledger.find_text_posting(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_request,r.event_id);
        ending:=meton_ledger.find_text_ending(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
        IF posting IS NULL OR ending IS NULL THEN
            RAISE EXCEPTION 'completion accounting requires reconciliation' USING ERRCODE='23514'; END IF;
    END IF;
    RETURN jsonb_build_object('version',1,'origin',jsonb_build_object('environment',p_env,'source',p_source,'user',p_user,'account',p_account,
        'source_marker',p_marker,'caller',p_caller,'operation_id',p_operation,'source_request_id',p_request),
        'event_id',r.event_id,'observation',r.observation,'posting',posting,'ending',ending);
END $$;

CREATE FUNCTION meton_ledger.complete_execution_text(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_hash text,p_spec jsonb,p_observation jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; old meton_ledger.text_completions%ROWTYPE; proof uuid; u jsonb; ready boolean;
    input_tokens bigint; output_tokens bigint; cached_tokens bigint; price meton_ledger.text_prices%ROWTYPE; amount numeric(20,8); terminal text;
BEGIN
    -- 不再要求用户 Key 仍然有效：已执行的原请求仍须记实耗。恢复代次与原归属继续由来源锁复验。
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF NOT EXISTS(SELECT FROM meton_ledger.text_executions e JOIN meton_ledger.text_transports t USING(request_id)
        WHERE e.request_id=p_request AND e.spec=p_spec AND t.context_hash=p_hash) THEN
        RAISE EXCEPTION 'different original execution evidence' USING ERRCODE='55000'; END IF;
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
    SELECT * INTO old FROM meton_ledger.text_completions WHERE request_id=p_request;
    IF FOUND THEN
        IF old.observation IS DISTINCT FROM p_observation THEN
            RAISE EXCEPTION 'original completion conflict' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.find_execution_result(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    END IF;
    INSERT INTO meton_ledger.text_completions(request_id,observation) VALUES(p_request,p_observation) RETURNING event_id INTO proof;
    IF ready THEN
        SELECT * INTO STRICT price FROM meton_ledger.text_prices WHERE (environment,source,protocol,model,version)=
            (p_env,p_source,h.protocol,h.model,h.price_version);
        input_tokens:=(u->>'input')::bigint; output_tokens:=(u->>'output')::bigint; cached_tokens:=(u->>'cached')::bigint;
        -- 固定原价格，整数计量、一次向上取到 8 位；原生浮点费用与后来发布的价格均不参与。
        amount:=ceil(((input_tokens-cached_tokens)*price.input_per_million+cached_tokens*price.cached_per_million+
            output_tokens*price.output_per_million)*price.multiplier*100)*0.00000001;
        -- 同一事务复用 S2-07 的扣减、补占差额与尾部释放；运行身份不因此获得这两个裸例程的权限。
        PERFORM meton_ledger.post_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
            p_request,proof,1,h.price_version,h.unit,amount::text,NULL,NULL,NULL);
        PERFORM meton_ledger.end_text_fees(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,proof,ARRAY[proof]);
    END IF;
    RETURN meton_ledger.find_execution_result(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
END $$;

REVOKE ALL ON TABLE meton_ledger.text_completions FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.complete_execution_text(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,text,jsonb,jsonb),
    meton_ledger.find_execution_result(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid) FROM PUBLIC;
