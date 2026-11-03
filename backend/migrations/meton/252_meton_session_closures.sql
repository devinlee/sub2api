-- 退出按原账号和逻辑会话永久截断在途签发，与同一账号的后来会话互相独立。
CREATE TABLE meton_managed_session_closures(
    operation uuid PRIMARY KEY, source_marker uuid NOT NULL REFERENCES meton_managed_creations(source_marker) ON DELETE RESTRICT,
    session_id uuid NOT NULL, claim jsonb NOT NULL, closure_marker uuid NOT NULL UNIQUE, closed_at timestamptz NOT NULL,
    UNIQUE(source_marker,session_id)
);
CREATE TRIGGER keep_meton_session_closure BEFORE UPDATE OR DELETE ON meton_managed_session_closures
    FOR EACH ROW EXECUTE FUNCTION keep_meton_key_origin();

CREATE FUNCTION deny_closed_meton_session_key() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.source_marker::text||':'||NEW.session_id::text,0));
    IF EXISTS(SELECT FROM public.meton_managed_session_closures WHERE source_marker=NEW.source_marker AND session_id=NEW.session_id) THEN
        RAISE EXCEPTION 'original session closed' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER deny_closed_meton_session_key BEFORE INSERT ON meton_managed_keys FOR EACH ROW EXECUTE FUNCTION deny_closed_meton_session_key();

-- 轮换和退出都先持有会话锁，再锁具体 Key。沿用 251 的全部轮换裁决，并避免两个路径反向等待。
ALTER FUNCTION meton_retire_key_for_rotation(text,text,bigint,jsonb,uuid,bigint,timestamptz) RENAME TO meton_retire_key_for_rotation_251;
CREATE FUNCTION meton_retire_key_for_rotation(p_env text,p_source text,p_epoch bigint,p_claim jsonb,p_marker uuid,p_key bigint,p_deadline timestamptz)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'source fenced' USING ERRCODE='55000'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(((p_claim->>'sourceMarker')::uuid)::text||':'||((p_claim->>'session')::uuid)::text,0));
    PERFORM public.meton_retire_key_for_rotation_251(p_env,p_source,p_epoch,p_claim,p_marker,p_key,p_deadline);
END $$;
REVOKE ALL ON FUNCTION meton_retire_key_for_rotation(text,text,bigint,jsonb,uuid,bigint,timestamptz) FROM PUBLIC;

CREATE FUNCTION meton_close_original_session(p_env text,p_source text,p_epoch bigint,p_claim jsonb,p_deadline timestamptz)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE o jsonb:=p_claim->'origin'; op uuid:=(p_claim->>'operation')::uuid; sess uuid:=(p_claim->>'session')::uuid;
        original public.meton_managed_creations%ROWTYPE; prior public.meton_managed_session_closures%ROWTYPE; stamp timestamptz;
BEGIN
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'source fenced' USING ERRCODE='55000'; END IF;
    SELECT m.* INTO original FROM public.meton_managed_creations m WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND
      o->>'environment'=p_env AND o->>'source'=p_source AND (o->>'epoch')::bigint=p_epoch
      AND m.meton_user=(o->>'user')::uuid AND m.account=(o->>'account')::uuid AND m.operation=(o->>'operation')::uuid AND m.dispatch=(o->>'dispatch')::uuid
      AND m.source_marker=(p_claim->>'sourceMarker')::uuid AND m.remote_user=(p_claim->>'remoteUser')::bigint FOR SHARE;
    IF NOT FOUND OR sess IS NULL OR op IS NULL OR '00000000-0000-0000-0000-000000000000'::uuid IN (sess,op) THEN
        RAISE EXCEPTION 'original session mismatch' USING ERRCODE='23505'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(original.source_marker::text||':'||sess::text,0));
    stamp:=clock_timestamp();
    IF p_deadline IS NULL OR p_deadline<=stamp OR p_deadline>stamp+interval '30 seconds' THEN RAISE EXCEPTION 'cleanup permit ended' USING ERRCODE='55000'; END IF;
    SELECT * INTO prior FROM public.meton_managed_session_closures WHERE source_marker=original.source_marker AND session_id=sess;
    IF FOUND THEN
        IF prior.operation<>op OR prior.claim IS DISTINCT FROM p_claim THEN RAISE EXCEPTION 'closure identity conflict' USING ERRCODE='23505'; END IF;
        RETURN;
    END IF;
    PERFORM k.id FROM public.api_keys k JOIN public.meton_managed_keys x ON k.id=x.remote_key WHERE x.source_marker=original.source_marker AND x.session_id=sess
      ORDER BY k.id FOR UPDATE OF k;
    stamp:=clock_timestamp();
    IF p_deadline<=stamp THEN RAISE EXCEPTION 'cleanup permit ended' USING ERRCODE='55000'; END IF;
    -- 已知原对象必须逐项吻合，不能因数值编号复用误停另一主体的 Key。
    IF EXISTS(SELECT FROM public.meton_managed_keys x LEFT JOIN public.api_keys k ON k.id=x.remote_key WHERE x.source_marker=original.source_marker
      AND x.session_id=sess AND (k.id IS NULL OR k.user_id IS DISTINCT FROM original.remote_user OR k.created_at IS DISTINCT FROM x.created_at
      OR k.expires_at IS DISTINCT FROM x.expires_at OR encode(sha256(convert_to(k.key,'UTF8')),'hex') IS DISTINCT FROM x.material_sha256)) THEN
        RAISE EXCEPTION 'native objects unconfirmed' USING ERRCODE='55000'; END IF;
    UPDATE public.api_keys k SET status='inactive',updated_at=stamp FROM public.meton_managed_keys x WHERE
      x.source_marker=original.source_marker AND x.session_id=sess AND k.id=x.remote_key AND k.user_id=original.remote_user
      AND k.created_at=x.created_at AND k.expires_at=x.expires_at AND encode(sha256(convert_to(k.key,'UTF8')),'hex')=x.material_sha256 AND k.status<>'inactive';
    -- 复用不可变的逐把停用证据，已有的轮换回执保留其原时刻。
    INSERT INTO public.meton_managed_key_retirements(operation,key_marker,remote_key,retired_at)
      SELECT x.operation,x.key_marker,x.remote_key,stamp FROM public.meton_managed_keys x WHERE x.source_marker=original.source_marker AND x.session_id=sess
      ON CONFLICT(operation) DO NOTHING;
    IF EXISTS(SELECT FROM public.meton_managed_keys x LEFT JOIN public.meton_managed_key_retirements r ON r.operation=x.operation AND r.key_marker=x.key_marker
      AND r.remote_key=x.remote_key LEFT JOIN public.api_keys k ON k.id=x.remote_key AND k.user_id=original.remote_user AND k.status='inactive'
      WHERE x.source_marker=original.source_marker AND x.session_id=sess AND (r.operation IS NULL OR k.id IS NULL)) THEN
        RAISE EXCEPTION 'closure incomplete' USING ERRCODE='55000'; END IF;
    IF p_deadline<=clock_timestamp() THEN RAISE EXCEPTION 'cleanup permit ended' USING ERRCODE='55000'; END IF;
    INSERT INTO public.meton_managed_session_closures VALUES(op,original.source_marker,sess,p_claim,gen_random_uuid(),stamp);
END $$;
REVOKE ALL ON FUNCTION meton_close_original_session(text,text,bigint,jsonb,timestamptz) FROM PUBLIC;
