-- 管理认证仍归原生中间件。资金事务复验并锁定它看到的密钥和管理员版本。
CREATE FUNCTION meton_ledger.lock_restored_shortfall_http_key(
    p_action text,p_request uuid,p_command uuid,p_generation integer,p_digest text,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE permission text; verifier text; expires timestamptz; deadline timestamptz;
BEGIN
    permission:=CASE p_action WHEN 'resolution' THEN 'meton.restored-shortfalls.read' WHEN 'original' THEN 'meton.restored-shortfalls.read'
        WHEN 'approve' THEN 'meton.restored-shortfalls.approve' WHEN 'apply' THEN 'meton.restored-shortfalls.apply' END;
    IF num_nulls(permission,p_request,p_command,p_generation,p_digest,p_key,p_creator,p_revision,p_until_ms,p_witness)>0 OR
        p_key !~ '^[a-f0-9]{24}$' OR p_creator<1 OR (CASE WHEN p_action='original' THEN p_generation<>0 ELSE p_generation<1 END) OR
        p_digest !~ '^[a-f0-9]{64}$' OR p_witness !~ '^[a-f0-9]{64}$' OR
        p_until_ms NOT BETWEEN floor(extract(epoch FROM clock_timestamp())*1000)::bigint+1 AND floor(extract(epoch FROM clock_timestamp())*1000)::bigint+30000 THEN
        RAISE EXCEPTION 'restored shortfall service authority unavailable' USING ERRCODE='42501'; END IF;
    deadline:=to_timestamp(p_until_ms::double precision/1000);
    SELECT k.key_hash,k.expires_at INTO verifier,expires FROM public.scoped_admin_api_keys k JOIN public.users u ON u.id=k.created_by
        WHERE k.id=p_key AND k.created_by=p_creator AND k.updated_at=p_revision AND k.enabled AND k.revoked_at IS NULL AND k.deleted_at IS NULL
          AND u.deleted_at IS NULL AND u.role='admin' AND u.status='active' AND jsonb_typeof(k.policy->'global_permissions')='array'
          AND (k.policy->'global_permissions') ? permission FOR SHARE OF k,u;
    IF NOT FOUND OR clock_timestamp()>=deadline OR (expires IS NOT NULL AND expires<deadline) OR
        p_witness IS DISTINCT FROM encode(sha256(convert_to(concat_ws('|','meton.restored-shortfall.http.v1',verifier,p_action,
            p_request,p_command,p_generation,p_digest,p_until_ms),'UTF8')),'hex') THEN
        RAISE EXCEPTION 'restored shortfall service authority unavailable' USING ERRCODE='42501'; END IF;
    RETURN deadline;
END $$;

-- 历史普通命令没有当前批准行，只能查原资金回执，不能补造批准或重新执行。
CREATE FUNCTION meton_ledger.http_find_restored_shortfall_original(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_command uuid,p_original text,p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; result jsonb;
BEGIN
    PERFORM meton_ledger.lock_restored_shortfall_http_key('original',p_request,p_command,0,p_original,p_key,p_creator,p_revision,p_until_ms,p_witness);
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN RETURN NULL; END IF;
    PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
    result:=meton_ledger.find_text_shortfall(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command);
    IF result->>'approval_digest' IS DISTINCT FROM p_original THEN RETURN NULL; END IF;
    RETURN result;
END $$;

CREATE FUNCTION meton_ledger.http_find_restored_shortfall_approval(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_command uuid,p_generation integer,p_digest text,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.lock_restored_shortfall_http_key('resolution',p_request,p_command,p_generation,p_digest,p_key,p_creator,p_revision,p_until_ms,p_witness);
    RETURN meton_ledger.find_restored_shortfall_approval(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_command,p_generation,p_digest);
END $$;

CREATE FUNCTION meton_ledger.http_approve_restored_shortfall(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_command uuid,p_case uuid,p_attempt uuid,p_original text,p_original_epoch bigint,
    p_generation integer,p_digest text,p_previous text,p_valid timestamptz,p_permit timestamptz,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE deadline timestamptz;
BEGIN
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    deadline:=meton_ledger.lock_restored_shortfall_http_key('approve',p_request,p_command,p_generation,p_digest,p_key,p_creator,p_revision,p_until_ms,p_witness);
    IF p_permit IS NULL OR p_permit>deadline OR has_function_privilege(session_user,
        'meton_ledger.http_cover_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,integer,text,timestamptz,text,bigint,timestamptz,bigint,text)','EXECUTE') THEN
        RAISE EXCEPTION 'unbound or combined shortfall authority' USING ERRCODE='42501'; END IF;
    RETURN meton_ledger.approve_restored_shortfall(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_command,p_case,p_attempt,p_original,p_original_epoch,p_generation,p_digest,p_previous,p_valid,p_permit);
END $$;

CREATE FUNCTION meton_ledger.http_cover_restored_shortfall(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_command uuid,p_generation integer,p_digest text,p_permit timestamptz,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE deadline timestamptz;
BEGIN
    -- 等账号锁之后才复验管理身份；在等待期间发生的撤销不能越过来源提交。
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    deadline:=meton_ledger.lock_restored_shortfall_http_key('apply',p_request,p_command,p_generation,p_digest,p_key,p_creator,p_revision,p_until_ms,p_witness);
    IF p_permit IS NULL OR p_permit>deadline OR has_function_privilege(session_user,
        'meton_ledger.http_approve_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,bigint,integer,text,text,timestamptz,timestamptz,text,bigint,timestamptz,bigint,text)','EXECUTE') THEN
        RAISE EXCEPTION 'unbound or combined shortfall authority' USING ERRCODE='42501'; END IF;
    RETURN meton_ledger.cover_restored_shortfall(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_command,p_generation,p_digest,p_permit);
END $$;

REVOKE ALL ON FUNCTION meton_ledger.lock_restored_shortfall_http_key(text,uuid,uuid,integer,text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_find_restored_shortfall_original(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_find_restored_shortfall_approval(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,integer,text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_approve_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,bigint,integer,text,text,timestamptz,timestamptz,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_cover_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,integer,text,timestamptz,text,bigint,timestamptz,bigint,text)
    FROM PUBLIC;
