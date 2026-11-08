-- 实际出站规格与原预占同事务保存；正文不落库，查询或旧 H 不能补造另一份可执行正文。
CREATE TABLE meton_ledger.text_executions (
    request_id uuid PRIMARY KEY REFERENCES meton_ledger.text_transports(request_id) ON DELETE RESTRICT,
    spec jsonb NOT NULL CHECK(jsonb_typeof(spec)='object')
);
CREATE TRIGGER immutable_text_execution BEFORE UPDATE OR DELETE ON meton_ledger.text_executions
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.text_executions ENABLE ALWAYS TRIGGER immutable_text_execution;

CREATE FUNCTION meton_ledger.reserve_execution_text(p_env text,p_source text,p_epoch bigint,p_context jsonb,p_hash text,p_gateway text,
    p_key bigint,p_spec jsonb)
RETURNS meton_ledger.text_hold_receipt LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid; prior uuid; original jsonb; receipt meton_ledger.text_hold_receipt;
BEGIN
    IF p_spec IS NULL OR jsonb_typeof(p_spec)<>'object' OR
       (p_spec ?& ARRAY['version','profile','profile_hash','wire_protocol','wire_model','target_hash','body_digest','input_bound','output_bound']) IS NOT TRUE OR
       (SELECT count(*) FROM jsonb_object_keys(p_spec))<>9 OR p_spec->>'version' IS DISTINCT FROM '1' OR
       jsonb_typeof(p_spec->'version') IS DISTINCT FROM 'number' OR
       EXISTS(SELECT 1 FROM jsonb_each(p_spec) WHERE key IN ('profile','profile_hash','wire_protocol','wire_model','target_hash','body_digest') AND jsonb_typeof(value)<>'string') OR
       coalesce(p_spec->>'profile','') !~ '^[A-Za-z0-9_.-]{1,120}$' OR coalesce(p_spec->>'wire_model','') !~ '^[A-Za-z0-9_./:-]{1,160}$' OR
       coalesce(p_spec->>'wire_protocol','') NOT IN ('responses','chat_completions') OR
       coalesce(p_spec->>'profile_hash','') !~ '^[0-9a-f]{64}$' OR coalesce(p_spec->>'target_hash','') !~ '^[0-9a-f]{64}$' OR
       coalesce(p_spec->>'body_digest','') !~ '^[0-9a-f]{64}$' OR
       jsonb_typeof(p_spec->'input_bound') IS DISTINCT FROM 'number' OR jsonb_typeof(p_spec->'output_bound') IS DISTINCT FROM 'number' OR
       coalesce((p_spec->>'input_bound')::integer,0) NOT BETWEEN 1 AND 100000000 OR
       coalesce((p_spec->>'output_bound')::integer,0) NOT BETWEEN 1 AND 100000000 THEN
        RAISE EXCEPTION 'invalid published text execution' USING ERRCODE='22023';
    END IF;
    SELECT m.source_marker INTO marker FROM public.meton_managed_creations m WHERE m.environment=p_env AND m.source=p_source AND
        m.epoch=p_epoch AND m.meton_user=(p_context->>'user')::uuid AND m.account=(p_context->>'account')::uuid;
    IF NOT FOUND THEN RAISE EXCEPTION 'execution owner unavailable' USING ERRCODE='42501'; END IF;
    -- 与原受理共用账户锁，使“已有原请求但没有执行规格”与首次插入不会竞态补接。
    PERFORM meton_ledger.lock_text_owner(p_env,p_source,p_epoch,(p_context->>'user')::uuid,(p_context->>'account')::uuid,marker);
    SELECT r.request_id INTO prior FROM meton_ledger.text_requests r WHERE r.source_marker=marker AND
        r.caller=p_context->>'caller' AND r.operation_id=(p_context->>'operation_id')::uuid;
    IF prior IS NOT NULL THEN
        SELECT spec INTO original FROM meton_ledger.text_executions WHERE request_id=prior;
        IF NOT FOUND OR original IS DISTINCT FROM p_spec THEN
            RAISE EXCEPTION 'original execution requires reconciliation' USING ERRCODE='23505';
        END IF;
    END IF;
    SELECT h.* INTO receipt FROM meton_ledger.reserve_transport_text(p_env,p_source,p_epoch,p_context,p_hash,p_gateway,p_key,
        (p_spec->>'input_bound')::integer,(p_spec->>'output_bound')::integer) h;
    IF prior IS NULL THEN INSERT INTO meton_ledger.text_executions(request_id,spec) VALUES(receipt.request_id,p_spec); END IF;
    IF timestamptz 'epoch'+(p_context->>'valid_until_ms')::bigint*interval '1 millisecond'<=clock_timestamp() THEN
        RAISE EXCEPTION 'original execution expired' USING ERRCODE='55000';
    END IF;
    RETURN receipt;
END $$;

CREATE FUNCTION meton_ledger.claim_execution_text(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_hash text,p_key bigint,p_key_hash text,p_spec jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF p_spec IS NULL OR NOT EXISTS(SELECT 1 FROM meton_ledger.text_executions WHERE request_id=p_request AND spec=p_spec) THEN
        RAISE EXCEPTION 'original execution unavailable' USING ERRCODE='55000';
    END IF;
    RETURN meton_ledger.claim_transport_text(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_hash,p_key,p_key_hash);
END $$;

REVOKE ALL ON TABLE meton_ledger.text_executions FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.reserve_execution_text(text,text,bigint,jsonb,text,text,bigint,jsonb),
    meton_ledger.claim_execution_text(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,text,bigint,text,jsonb) FROM PUBLIC;
