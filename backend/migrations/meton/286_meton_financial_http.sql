-- 只读观察不锁管理员行；取得快照后另用新语句复核当前权限，不能沿用原快照放行交付。
CREATE FUNCTION meton_ledger.check_http_financial_observation(
 p_env text,p_source text,p_epoch bigint,p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE verifier text; expires timestamptz; deadline timestamptz;
BEGIN
 IF num_nulls(p_env,p_source,p_epoch,p_key,p_creator,p_revision,p_until_ms,p_witness)>0 OR
  p_env !~ '^[A-Za-z0-9_.-]{1,120}$' OR p_source !~ '^[A-Za-z0-9_.-]{1,120}$' OR p_epoch<1 OR
  p_key !~ '^[a-f0-9]{24}$' OR p_creator<1 OR p_witness !~ '^[a-f0-9]{64}$' OR
  p_until_ms NOT BETWEEN floor(extract(epoch FROM clock_timestamp())*1000)::bigint+1 AND floor(extract(epoch FROM clock_timestamp())*1000)::bigint+5000 OR
  current_setting('transaction_isolation')<>'read committed' OR current_setting('transaction_read_only')<>'on' OR
  current_setting('statement_timeout')::interval NOT BETWEEN interval '1 millisecond' AND interval '5 seconds' OR
  pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR
  pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_ledger','CREATE') OR
  NOT EXISTS(SELECT FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch) THEN
  RAISE EXCEPTION 'financial observation authority unavailable' USING ERRCODE='42501'; END IF;
 deadline:=to_timestamp(p_until_ms::double precision/1000);
 SELECT k.key_hash,k.expires_at INTO verifier,expires FROM public.scoped_admin_api_keys k JOIN public.users u ON u.id=k.created_by
  WHERE k.id=p_key AND k.created_by=p_creator AND k.updated_at=p_revision AND k.enabled AND k.revoked_at IS NULL AND k.deleted_at IS NULL
  AND u.deleted_at IS NULL AND u.role='admin' AND u.status='active' AND jsonb_typeof(k.policy->'global_permissions')='array'
  AND (k.policy->'global_permissions') ? 'meton.financial.observe';
 IF NOT FOUND OR clock_timestamp()>=deadline OR (expires IS NOT NULL AND expires<deadline) OR
  p_witness IS DISTINCT FROM encode(sha256(convert_to(concat_ws('|','meton.financial.http.v1',verifier,p_env,p_source,p_epoch,p_key,p_creator,p_until_ms),'UTF8')),'hex') THEN
  RAISE EXCEPTION 'financial observation authority unavailable' USING ERRCODE='42501'; END IF;
 RETURN true;
END $$;

CREATE FUNCTION meton_ledger.http_read_financial_observation(
 p_env text,p_source text,p_epoch bigint,p_key text,p_creator bigint,p_revision timestamptz,p_until_ms bigint,p_witness text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 PERFORM meton_ledger.check_http_financial_observation(p_env,p_source,p_epoch,p_key,p_creator,p_revision,p_until_ms,p_witness);
 RETURN meton_ledger.read_financial_observation(p_env,p_source,p_epoch);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.check_http_financial_observation(text,text,bigint,text,bigint,timestamptz,bigint,text),
 meton_ledger.http_read_financial_observation(text,text,bigint,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
