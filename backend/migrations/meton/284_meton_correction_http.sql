-- 原管理中间件负责认证。这里核对它当时看到的密钥版本并锁住原行，避免账号锁等待期间的撤销漏过资金提交。
CREATE FUNCTION meton_ledger.lock_http_correction_key(
    p_action text,p_request uuid,p_item uuid,p_basis uuid,p_decision uuid,p_digest text,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE permission text; verifier text; expires timestamptz; deadline timestamptz;
BEGIN
    permission:=CASE p_action WHEN 'basis' THEN 'meton.corrections.read' WHEN 'resolution' THEN 'meton.corrections.read'
        WHEN 'approve' THEN 'meton.corrections.approve' WHEN 'apply' THEN 'meton.corrections.apply' END;
    IF num_nulls(permission,p_request,p_item,p_basis,p_key,p_creator,p_revision,p_until_ms,p_witness)>0 OR
        p_key !~ '^[a-f0-9]{24}$' OR p_creator<1 OR p_witness !~ '^[a-f0-9]{64}$' OR
        p_until_ms NOT BETWEEN floor(extract(epoch FROM clock_timestamp())*1000)::bigint+1 AND floor(extract(epoch FROM clock_timestamp())*1000)::bigint+30000 THEN
        RAISE EXCEPTION 'correction service authority unavailable' USING ERRCODE='42501';
    END IF;
    deadline:=to_timestamp(p_until_ms::double precision/1000);
    SELECT k.key_hash,k.expires_at INTO verifier,expires FROM public.scoped_admin_api_keys k JOIN public.users u ON u.id=k.created_by
        WHERE k.id=p_key AND k.created_by=p_creator AND k.updated_at=p_revision AND k.enabled AND k.revoked_at IS NULL AND k.deleted_at IS NULL
          AND u.deleted_at IS NULL AND u.role='admin' AND u.status='active' AND jsonb_typeof(k.policy->'global_permissions')='array'
          AND (k.policy->'global_permissions') ? permission FOR SHARE OF k,u;
    IF NOT FOUND OR clock_timestamp()>=deadline OR (expires IS NOT NULL AND expires<deadline) OR
        p_witness IS DISTINCT FROM encode(sha256(convert_to(concat_ws('|','meton.correction.http.v1',verifier,p_action,p_request,p_item,p_basis,
                                  coalesce(p_decision::text,'-'),coalesce(p_digest,'-'),p_until_ms),'UTF8')),'hex') THEN
        RAISE EXCEPTION 'correction service authority unavailable' USING ERRCODE='42501';
    END IF;
    RETURN deadline;
END $$;

CREATE FUNCTION meton_ledger.http_read_operations_correction_basis(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_limit integer,p_cursor jsonb,p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.lock_http_correction_key('basis',p_request,p_item,p_basis,NULL,NULL,p_key,p_creator,p_revision,p_until_ms,p_witness);
    RETURN meton_ledger.read_operations_correction_basis(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_limit,p_cursor);
END $$;

CREATE FUNCTION meton_ledger.http_find_operations_correction(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_decision uuid,p_case uuid,p_attempt uuid,p_version integer,p_generation integer,p_digest text,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.lock_http_correction_key('resolution',p_request,p_item,p_basis,p_decision,p_digest,p_key,p_creator,p_revision,p_until_ms,p_witness);
    RETURN meton_ledger.find_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest);
END $$;

CREATE FUNCTION meton_ledger.http_approve_operations_correction(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_decision uuid,p_case uuid,p_attempt uuid,p_version integer,p_generation integer,p_digest text,
    p_previous text,p_final boolean,p_sources jsonb,p_valid timestamptz,p_permit timestamptz,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE deadline timestamptz;
BEGIN
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    deadline:=meton_ledger.lock_http_correction_key('approve',p_request,p_item,p_basis,p_decision,p_digest,p_key,p_creator,p_revision,p_until_ms,p_witness);
    IF p_permit IS NULL OR p_permit>deadline THEN RAISE EXCEPTION 'unbound correction permit' USING ERRCODE='42501'; END IF;
    RETURN meton_ledger.approve_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest,p_previous,p_final,p_sources,p_valid,p_permit);
END $$;

CREATE FUNCTION meton_ledger.http_apply_operations_correction(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_decision uuid,p_case uuid,p_attempt uuid,p_version integer,p_generation integer,p_digest text,p_permit timestamptz,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE deadline timestamptz;
BEGIN
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    deadline:=meton_ledger.lock_http_correction_key('apply',p_request,p_item,p_basis,p_decision,p_digest,p_key,p_creator,p_revision,p_until_ms,p_witness);
    IF p_permit IS NULL OR p_permit>deadline THEN RAISE EXCEPTION 'unbound correction permit' USING ERRCODE='42501'; END IF;
    RETURN meton_ledger.apply_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest,p_permit);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.lock_http_correction_key(text,uuid,uuid,uuid,uuid,text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_read_operations_correction_basis(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,integer,jsonb,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_find_operations_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,integer,integer,text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_approve_operations_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,integer,integer,text,text,boolean,jsonb,timestamptz,timestamptz,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_apply_operations_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,integer,integer,text,timestamptz,text,bigint,timestamptz,bigint,text)
    FROM PUBLIC;
