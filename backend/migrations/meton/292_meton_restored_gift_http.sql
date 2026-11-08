-- 原生认证的当前身份在等到账号锁后再次验证；正文不得提供这些证明字段。
CREATE FUNCTION meton_ledger.restored_gift_http(
    p_action text,p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; t jsonb; permission text; verifier text; expires timestamptz; deadline timestamptz; allowed regprocedure;
BEGIN
    permission=CASE p_action WHEN 'inspect' THEN 'meton.restored-gifts.read' WHEN 'reconcile' THEN 'meton.restored-gifts.reconcile' END;
    IF num_nulls(permission,p_registration,p_identity_event,p_security,p_identity_epoch,p_key,p_creator,p_revision,p_until_ms,p_witness)>0 OR
        p_key !~ '^[a-f0-9]{24}$' OR p_creator<1 OR p_security<1 OR p_identity_epoch<1 OR p_witness !~ '^[a-f0-9]{64}$' THEN
        RAISE EXCEPTION 'restored gift HTTP authority unavailable' USING ERRCODE='42501'; END IF;
    -- 来源查询先锁原账号；等待期间发生的撤销和恢复不能沿旧快照进入资金提交。
    result=meton_ledger.find_restored_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,p_original_epoch,p_decision);
    t=result->'termination';
    IF ((t->>'registration')::uuid,(t->>'identity_event')::uuid,(t->>'security_version')::bigint,(t->>'identity_epoch')::bigint)
        IS DISTINCT FROM (p_registration,p_identity_event,p_security,p_identity_epoch) THEN
        RAISE EXCEPTION 'original final identity proof changed' USING ERRCODE='42501'; END IF;
    allowed=(CASE p_action WHEN 'inspect' THEN 'meton_ledger.http_find_restored_gift_termination' ELSE 'meton_ledger.http_reconcile_restored_gift_termination' END
        ||'(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid,uuid,uuid,bigint,bigint,text,bigint,timestamptz,bigint,text)')::regprocedure;
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname=session_user AND rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls) OR
        EXISTS(SELECT FROM pg_proc p WHERE p.pronamespace='meton_ledger'::regnamespace AND p.oid<>allowed AND has_function_privilege(session_user,p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'restored gift database role unavailable' USING ERRCODE='42501'; END IF;
    IF p_until_ms NOT BETWEEN floor(extract(epoch FROM clock_timestamp())*1000)::bigint+1 AND floor(extract(epoch FROM clock_timestamp())*1000)::bigint+30000 THEN
        RAISE EXCEPTION 'restored gift HTTP authority expired' USING ERRCODE='42501'; END IF;
    deadline=to_timestamp(p_until_ms::double precision/1000);
    SELECT k.key_hash,k.expires_at INTO verifier,expires FROM public.scoped_admin_api_keys k JOIN public.users u ON u.id=k.created_by
        WHERE k.id=p_key AND k.created_by=p_creator AND k.updated_at=p_revision AND k.enabled AND k.revoked_at IS NULL AND k.deleted_at IS NULL
          AND u.deleted_at IS NULL AND u.role='admin' AND u.status='active' AND jsonb_typeof(k.policy->'global_permissions')='array'
          AND (k.policy->'global_permissions') ? permission FOR SHARE OF k,u;
    IF NOT FOUND OR clock_timestamp()>=deadline OR (expires IS NOT NULL AND expires<deadline) OR
        p_witness IS DISTINCT FROM encode(sha256(convert_to(concat_ws('|','meton.restored-gift.http.v1',verifier,p_action,p_marker,p_decision,
            p_epoch,p_original_epoch,p_registration,p_identity_event,p_security,p_identity_epoch,p_until_ms),'UTF8')),'hex') THEN
        RAISE EXCEPTION 'restored gift HTTP authority unavailable' USING ERRCODE='42501'; END IF;
    IF p_action='reconcile' THEN
        result=meton_ledger.reconcile_restored_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,p_original_epoch,p_decision);
    END IF;
    IF clock_timestamp()>=deadline THEN RAISE EXCEPTION 'restored gift HTTP authority expired' USING ERRCODE='42501'; END IF;
    RETURN result;
END $$;

CREATE FUNCTION meton_ledger.http_find_restored_gift_termination(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.restored_gift_http('inspect',p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
        p_original_epoch,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch,p_key,p_creator,p_revision,p_until_ms,p_witness)
$$;
CREATE FUNCTION meton_ledger.http_reconcile_restored_gift_termination(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.restored_gift_http('reconcile',p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
        p_original_epoch,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch,p_key,p_creator,p_revision,p_until_ms,p_witness)
$$;

REVOKE ALL ON FUNCTION
    meton_ledger.restored_gift_http(text,text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid,uuid,uuid,bigint,bigint,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_find_restored_gift_termination(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid,uuid,uuid,bigint,bigint,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_reconcile_restored_gift_termination(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid,uuid,uuid,bigint,bigint,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
