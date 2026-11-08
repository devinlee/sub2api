-- 只在最终供应请求已确定时固定账户和认证摘要；不保留密钥或正文，不替旧调用补造绑定。
CREATE TABLE meton_ledger.text_provider_bindings (
 request_id uuid PRIMARY KEY REFERENCES meton_ledger.text_executions(request_id) ON DELETE RESTRICT,
 binding jsonb NOT NULL CHECK(jsonb_typeof(binding)='object')
);
CREATE TRIGGER immutable_text_provider BEFORE UPDATE OR DELETE ON meton_ledger.text_provider_bindings
 FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.text_provider_bindings ENABLE ALWAYS TRIGGER immutable_text_provider;

CREATE FUNCTION meton_ledger.reserve_provider_execution_text(p_env text,p_source text,p_epoch bigint,p_context jsonb,p_hash text,p_gateway text,
 p_key bigint,p_spec jsonb,p_binding jsonb)
RETURNS meton_ledger.text_hold_receipt LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid; prior uuid; original jsonb; receipt meton_ledger.text_hold_receipt;
BEGIN
 IF p_binding IS NULL OR jsonb_typeof(p_binding)<>'object' OR
  (p_binding ?& ARRAY['version','account','credential_hash','query_kind']) IS NOT TRUE OR
  (SELECT count(*) FROM jsonb_object_keys(p_binding))<>4 OR p_binding->'version' IS DISTINCT FROM '1'::jsonb OR
  jsonb_typeof(p_binding->'account') IS DISTINCT FROM 'number' OR (p_binding->>'account') !~ '^[1-9][0-9]{0,17}$' OR
  jsonb_typeof(p_binding->'credential_hash') IS DISTINCT FROM 'string' OR (p_binding->>'credential_hash') !~ '^[0-9a-f]{64}$' OR
  jsonb_typeof(p_binding->'query_kind') IS DISTINCT FROM 'string' OR p_binding->>'query_kind' NOT IN ('unavailable','responses_default') OR
  p_binding->>'query_kind'='responses_default' AND p_spec->>'wire_protocol' IS DISTINCT FROM 'responses' THEN
  RAISE EXCEPTION 'invalid original provider binding' USING ERRCODE='22023';
 END IF;
 SELECT m.source_marker INTO marker FROM public.meton_managed_creations m WHERE m.environment=p_env AND m.source=p_source AND
  m.epoch=p_epoch AND m.meton_user=(p_context->>'user')::uuid AND m.account=(p_context->>'account')::uuid;
 IF NOT FOUND THEN RAISE EXCEPTION 'original provider owner unavailable' USING ERRCODE='42501'; END IF;
 PERFORM meton_ledger.lock_text_owner(p_env,p_source,p_epoch,(p_context->>'user')::uuid,(p_context->>'account')::uuid,marker);
 SELECT request_id INTO prior FROM meton_ledger.text_requests WHERE source_marker=marker AND caller=p_context->>'caller' AND operation_id=(p_context->>'operation_id')::uuid;
 IF prior IS NOT NULL THEN
  SELECT binding INTO original FROM meton_ledger.text_provider_bindings WHERE request_id=prior;
  IF NOT FOUND OR original IS DISTINCT FROM p_binding THEN
   RAISE EXCEPTION 'original provider binding conflict' USING ERRCODE='23505';
  END IF;
 END IF;
 SELECT h.* INTO receipt FROM meton_ledger.reserve_execution_text(p_env,p_source,p_epoch,p_context,p_hash,p_gateway,p_key,p_spec) h;
 IF prior IS NULL THEN INSERT INTO meton_ledger.text_provider_bindings(request_id,binding) VALUES(receipt.request_id,p_binding); END IF;
 RETURN receipt;
END $$;

CREATE FUNCTION meton_ledger.find_provider_original(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb; material jsonb;
BEGIN
 result:=meton_ledger.find_execution_result(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
 IF result IS NULL OR (result->'observation'->>'fee_ready')::boolean THEN RETURN NULL; END IF;
 SELECT jsonb_build_object('version',1,'origin',result->'origin','prior_event',result->>'event_id','context_hash',t.context_hash,
  'spec',e.spec,'binding',b.binding,'observation',result->'observation') INTO material
 FROM meton_ledger.text_provider_bindings b JOIN meton_ledger.text_executions e USING(request_id)
 JOIN meton_ledger.text_transports t USING(request_id) JOIN meton_ledger.text_requests r USING(request_id)
 WHERE b.request_id=p_request AND r.epoch_at_accept=p_epoch;
 RETURN material;
END $$;

REVOKE ALL ON TABLE meton_ledger.text_provider_bindings FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.reserve_provider_execution_text(text,text,bigint,jsonb,text,text,bigint,jsonb,jsonb),
 meton_ledger.find_provider_original(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid) FROM PUBLIC;
