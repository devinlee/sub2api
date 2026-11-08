-- 原发送者与来源受理同事务固定。旧调用没有这份证明时只能核对，不能补造新的发送资格。
CREATE TABLE meton_ledger.text_transports (
    request_id uuid PRIMARY KEY REFERENCES meton_ledger.text_requests(request_id) ON DELETE RESTRICT,
    dispatch uuid NOT NULL UNIQUE, worker uuid NOT NULL, gateway text NOT NULL,
    context_hash text NOT NULL CHECK(context_hash ~ '^[0-9a-f]{64}$'), context jsonb NOT NULL,
    valid_until timestamptz NOT NULL,
    CHECK(dispatch<>'00000000-0000-0000-0000-000000000000' AND worker<>'00000000-0000-0000-0000-000000000000'),
    CHECK(gateway ~ '^[A-Za-z0-9_.-]{1,120}$')
);
CREATE TRIGGER immutable_text_transport BEFORE UPDATE OR DELETE ON meton_ledger.text_transports
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.text_transports ENABLE ALWAYS TRIGGER immutable_text_transport;

CREATE FUNCTION meton_ledger.reserve_transport_text(p_env text,p_source text,p_epoch bigint,p_context jsonb,p_hash text,p_gateway text,
    p_key bigint,p_input integer,p_output integer)
RETURNS meton_ledger.text_hold_receipt LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid; remote_id bigint; prior uuid; receipt meton_ledger.text_hold_receipt; transport meton_ledger.text_transports%ROWTYPE;
    until_at timestamptz; u uuid:=(p_context->>'user')::uuid; a uuid:=(p_context->>'account')::uuid;
    call_name text:=p_context->>'caller'; operation uuid:=(p_context->>'operation_id')::uuid;
BEGIN
    IF p_context IS NULL OR jsonb_typeof(p_context)<>'object' OR
       (p_context ?& ARRAY['version','environment','source','user','account','caller','operation_id','protocol','model','digest_version','input_digest',
         'epoch','session','family','security_version','identity_recovery_version','binding','generation','service_version','token_id','model_grant_id',
         'worker','dispatch','valid_until_ms','key_digest']) IS NOT TRUE OR (SELECT count(*) FROM jsonb_object_keys(p_context))<>25 OR
       p_context->>'version' IS DISTINCT FROM '1' OR p_context->>'environment' IS DISTINCT FROM p_env OR
       p_context->>'source' IS DISTINCT FROM p_source OR p_context->>'epoch' IS DISTINCT FROM p_epoch::text OR
       p_hash IS NULL OR p_hash !~ '^[0-9a-f]{64}$' OR p_gateway IS NULL OR p_gateway !~ '^[A-Za-z0-9_.-]{1,120}$' OR
       coalesce((p_context->>'service_version')::bigint,0)<1 OR
       coalesce((p_context->>'token_id')::uuid,'00000000-0000-0000-0000-000000000000')='00000000-0000-0000-0000-000000000000' OR
       coalesce((p_context->>'model_grant_id')::uuid,'00000000-0000-0000-0000-000000000000')='00000000-0000-0000-0000-000000000000' THEN
        RAISE EXCEPTION 'invalid original transport context' USING ERRCODE='22023';
    END IF;
    -- 来源标记和原生用户只从现有 Key 的原签发证明取得，不能由外来上下文指定。
    SELECT m.source_marker,m.remote_user INTO marker,remote_id FROM public.meton_managed_creations m
        JOIN public.meton_managed_keys k ON k.source_marker=m.source_marker
        WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND m.meton_user=u AND m.account=a
          AND k.remote_key=p_key AND k.meton_user=u AND k.session_id=(p_context->>'session')::uuid
          AND k.binding=(p_context->>'binding')::uuid AND k.generation=(p_context->>'generation')::bigint
          AND k.claim->>'family'=p_context->>'family' AND k.claim->>'securityVersion'=p_context->>'security_version'
          AND k.claim->>'identityRecoveryVersion'=p_context->>'identity_recovery_version' AND k.material_sha256=p_context->>'key_digest';
    IF NOT FOUND THEN RAISE EXCEPTION 'original session mismatch' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.lock_text_owner(p_env,p_source,p_epoch,u,a,marker);
    PERFORM meton_ledger.lock_text_key(p_env,p_source,p_epoch,remote_id,p_key,p_context->>'key_digest');
    until_at:=timestamptz 'epoch'+(p_context->>'valid_until_ms')::bigint*interval '1 millisecond';
    IF until_at IS NULL OR until_at<=clock_timestamp() OR until_at>clock_timestamp()+interval '31 seconds' THEN
        RAISE EXCEPTION 'original transport expired' USING ERRCODE='55000';
    END IF;
    SELECT r.request_id INTO prior FROM meton_ledger.text_requests r WHERE r.source_marker=marker AND r.caller=call_name AND r.operation_id=operation;
    SELECT h.* INTO receipt FROM meton_ledger.reserve_text(p_env,p_source,p_epoch,u,a,marker,call_name,operation,p_key,p_context->>'key_digest',
        p_context->>'protocol',p_context->>'model',(p_context->>'digest_version')::integer,p_context->>'input_digest',p_input,p_output) h;
    IF prior IS NOT NULL THEN
        SELECT * INTO transport FROM meton_ledger.text_transports WHERE request_id=prior;
        IF NOT FOUND OR transport.context IS DISTINCT FROM p_context OR transport.context_hash IS DISTINCT FROM p_hash OR transport.gateway IS DISTINCT FROM p_gateway THEN
            RAISE EXCEPTION 'original sender requires reconciliation' USING ERRCODE='23505';
        END IF;
    ELSE
        INSERT INTO meton_ledger.text_transports(request_id,dispatch,worker,gateway,context_hash,context,valid_until)
            VALUES(receipt.request_id,(p_context->>'dispatch')::uuid,(p_context->>'worker')::uuid,p_gateway,p_hash,p_context,until_at);
    END IF;
    -- 首次预占和证明之间若被阻塞，整个事务回滚；过期证明不能留下可派发的半份记录。
    IF until_at<=clock_timestamp() THEN RAISE EXCEPTION 'original transport expired' USING ERRCODE='55000'; END IF;
    RETURN receipt;
END $$;

CREATE FUNCTION meton_ledger.claim_transport_text(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_hash text,p_key bigint,p_key_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE transport meton_ledger.text_transports%ROWTYPE; first boolean;
BEGIN
    SELECT t.* INTO transport FROM meton_ledger.text_transports t JOIN meton_ledger.text_requests r USING(request_id)
        WHERE t.request_id=p_request AND t.context_hash=p_hash AND r.environment=p_env AND r.source=p_source AND r.epoch_at_accept=p_epoch
          AND r.source_marker=p_marker AND r.caller=p_caller AND r.operation_id=p_operation
          AND t.context->>'user'=p_user::text AND t.context->>'account'=p_account::text AND t.context->>'key_digest'=p_key_hash;
    IF NOT FOUND OR transport.valid_until<=clock_timestamp() THEN
        RAISE EXCEPTION 'original transport unavailable' USING ERRCODE='55000';
    END IF;
    first:=meton_ledger.claim_text_dispatch(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_key,p_key_hash);
    -- 原例程会等待账户与 Key 锁；等待结束后再校验截止，否则过期发送者仍可能得到首次许可。
    IF transport.valid_until<=clock_timestamp() THEN RAISE EXCEPTION 'original transport expired' USING ERRCODE='55000'; END IF;
    RETURN first;
END $$;

REVOKE ALL ON TABLE meton_ledger.text_transports FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.reserve_transport_text(text,text,bigint,jsonb,text,text,bigint,integer,integer),
    meton_ledger.claim_transport_text(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,text,bigint,text) FROM PUBLIC;
