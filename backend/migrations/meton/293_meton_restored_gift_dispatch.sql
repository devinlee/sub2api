-- 原决定可以尚未在来源执行；查无只说明本次快照，不授予 Meton 重新派发资格。
CREATE FUNCTION meton_ledger.find_restored_pending_gift(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE expected meton_ledger.gift_terminations%ROWTYPE;t meton_ledger.gift_terminations%ROWTYPE;
BEGIN
    IF num_nulls(p_original_epoch,p_epoch,p_eligibility,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch)>0 OR
        p_original_epoch<1 OR p_epoch<=p_original_epoch OR p_security<1 OR p_identity_epoch<1 OR
        '00000000-0000-0000-0000-000000000000'::uuid IN (p_eligibility,p_decision,p_registration,p_identity_event) THEN
        RAISE EXCEPTION 'explicit original final identity required' USING ERRCODE='22023'; END IF;
    expected=jsonb_populate_record(NULL::meton_ledger.gift_terminations,jsonb_build_object(
        'environment',p_env,'source',p_source,'epoch',p_original_epoch,'meton_user',p_user,'account',p_account,'creation',p_creation,
        'dispatch',p_dispatch,'remote_user',p_remote,'source_marker',p_marker,'eligibility',p_eligibility,'decision',p_decision,
        'registration',p_registration,'identity_event',p_identity_event,'security_version',p_security,'identity_epoch',p_identity_epoch));
    -- 先取得当前原账号锁并验证完整历史链，再读原决定，避免等锁前的查无变成写入依据。
    PERFORM meton_ledger.require_gift_termination_epoch(expected,p_epoch);
    SELECT * INTO t FROM meton_ledger.gift_terminations WHERE source_marker=p_marker;
    IF t.decision IS NOT NULL AND (to_jsonb(t)-ARRAY['cutoff_sequence','recorded_at']) IS DISTINCT FROM
        (to_jsonb(expected)-ARRAY['cutoff_sequence','recorded_at']) OR
        EXISTS(SELECT FROM meton_ledger.gift_terminations WHERE decision=p_decision AND source_marker<>p_marker) THEN
        RAISE EXCEPTION 'original final gift decision changed' USING ERRCODE='23505'; END IF;
    RETURN jsonb_build_object('environment',p_env,'source',p_source,'epoch',p_original_epoch,'authority_epoch',p_epoch,'user',p_user,
        'account',p_account,'creation',p_creation,'dispatch',p_dispatch,'remote_user',p_remote,'source_marker',p_marker,'eligibility',p_eligibility,
        'funds',meton_ledger.gift_state(p_marker,p_eligibility),'termination',CASE WHEN t.decision IS NULL THEN NULL ELSE to_jsonb(t) END,
        'retired',coalesce((SELECT sum(amount) FROM meton_ledger.gift_retirements WHERE decision=t.decision),0)::numeric(20,8)::text,
        'effects',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.effect) FROM meton_ledger.gift_retirements r WHERE r.decision=t.decision),'[]'::jsonb));
END $$;

CREATE FUNCTION meton_ledger.terminate_restored_gift(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb;part record;
BEGIN
    result=meton_ledger.find_restored_pending_gift(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
        p_original_epoch,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch);
    IF result->'termination'<>'null'::jsonb OR result->'funds'->>'state' NOT IN ('empty','gift_only') THEN RETURN result; END IF;
    -- 当前权限只决定能否执行，流水仍归原账号、原决定和原代次；复用原批次核销算法。
    INSERT INTO meton_ledger.gift_terminations(decision,source_marker,environment,source,epoch,meton_user,account,creation,dispatch,remote_user,
        eligibility,registration,identity_event,security_version,identity_epoch,cutoff_sequence)
        VALUES(p_decision,p_marker,p_env,p_source,p_original_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_eligibility,p_registration,
            p_identity_event,p_security,p_identity_epoch,coalesce((SELECT last_sequence FROM meton_ledger.accounts WHERE source_marker=p_marker),0));
    FOR part IN SELECT g.event_id,l.remaining FROM meton_ledger.registration_grants g JOIN meton_ledger.lots l ON l.credit_event=g.event_id
        WHERE g.source_marker=p_marker AND g.eligibility=p_eligibility LOOP
        PERFORM meton_ledger.retire_gift_part(p_decision,part.event_id,NULL,part.remaining);
    END LOOP;
    RETURN meton_ledger.find_restored_pending_gift(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
        p_original_epoch,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch);
END $$;

REVOKE ALL ON FUNCTION
    meton_ledger.find_restored_pending_gift(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid,uuid,uuid,bigint,bigint),
    meton_ledger.terminate_restored_gift(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid,uuid,uuid,bigint,bigint) FROM PUBLIC;

CREATE OR REPLACE FUNCTION meton_ledger.restored_gift_http(
    p_action text,p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; t jsonb; permission text; verifier text; expires timestamptz; deadline timestamptz; allowed regprocedure;
BEGIN
    permission=CASE p_action WHEN 'inspect' THEN 'meton.restored-gifts.read' WHEN 'reconcile' THEN 'meton.restored-gifts.reconcile' WHEN 'terminate' THEN 'meton.restored-gifts.terminate' END;
    IF num_nulls(permission,p_registration,p_identity_event,p_security,p_identity_epoch,p_key,p_creator,p_revision,p_until_ms,p_witness)>0 OR
        p_key !~ '^[a-f0-9]{24}$' OR p_creator<1 OR p_security<1 OR p_identity_epoch<1 OR p_witness !~ '^[a-f0-9]{64}$' THEN
        RAISE EXCEPTION 'restored gift HTTP authority unavailable' USING ERRCODE='42501'; END IF;
    -- 来源查询先锁原账号；等待期间发生的撤销和恢复不能沿旧快照进入资金提交。
    result=meton_ledger.find_restored_pending_gift(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
        p_original_epoch,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch);
    IF p_action='reconcile' AND result->'termination'='null'::jsonb THEN
        RAISE EXCEPTION 'original gift termination missing' USING ERRCODE='55000'; END IF;
    allowed=(CASE p_action WHEN 'inspect' THEN 'meton_ledger.http_find_restored_gift_termination' WHEN 'reconcile' THEN 'meton_ledger.http_reconcile_restored_gift_termination' ELSE 'meton_ledger.http_terminate_restored_gift' END
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
    IF p_action='terminate' THEN
        result=meton_ledger.terminate_restored_gift(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
            p_original_epoch,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch);
    ELSIF p_action='reconcile' THEN
        result=meton_ledger.reconcile_restored_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,p_original_epoch,p_decision);
    END IF;
    IF clock_timestamp()>=deadline THEN RAISE EXCEPTION 'restored gift HTTP authority expired' USING ERRCODE='42501'; END IF;
    RETURN result;
END $$;

CREATE FUNCTION meton_ledger.http_terminate_restored_gift(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint,
    p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.restored_gift_http('terminate',p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
        p_original_epoch,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch,p_key,p_creator,p_revision,p_until_ms,p_witness)
$$;

REVOKE ALL ON FUNCTION meton_ledger.http_terminate_restored_gift(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid,uuid,uuid,bigint,bigint,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
