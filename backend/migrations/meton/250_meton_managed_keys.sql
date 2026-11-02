-- 来源记录绑定在原账号创建、会话、代次及派发。用户 Key 只保存在原生服务自己的 api_keys 表。
CREATE TABLE meton_managed_keys (
    operation uuid PRIMARY KEY, binding uuid NOT NULL UNIQUE, dispatch uuid NOT NULL UNIQUE,
    source_marker uuid NOT NULL REFERENCES meton_managed_creations(source_marker) ON DELETE RESTRICT,
    meton_user uuid NOT NULL, session_id uuid NOT NULL, generation bigint NOT NULL CHECK(generation>0),
    claim jsonb NOT NULL, key_marker uuid NOT NULL UNIQUE, remote_key bigint NOT NULL UNIQUE REFERENCES api_keys(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, material_sha256 text NOT NULL CHECK(length(material_sha256)=64),
    UNIQUE(source_marker,session_id,generation), CHECK(expires_at>created_at AND expires_at<=created_at+interval '24 hours')
);
CREATE FUNCTION meton_issue_managed_key(p_env text,p_source text,p_epoch bigint,p_claim jsonb,p_deadline timestamptz,p_secret text)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE o jsonb := p_claim->'origin'; creation public.meton_managed_creations%ROWTYPE; prior public.meton_managed_keys%ROWTYPE;
        op uuid := (p_claim->>'operation')::uuid; binder uuid := (p_claim->>'binding')::uuid; disp uuid := (p_claim->>'dispatch')::uuid;
        sess uuid := (p_claim->>'session')::uuid; family uuid := (p_claim->>'family')::uuid; gen bigint := (p_claim->>'generation')::bigint;
        stamp timestamptz; ending timestamptz; kid bigint;
BEGIN
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'key source unavailable' USING ERRCODE='55000'; END IF;
    SELECT m.* INTO creation FROM public.meton_managed_creations m JOIN public.users u ON u.id=m.remote_user
      WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND m.operation=(o->>'operation')::uuid AND m.dispatch=(o->>'dispatch')::uuid
      AND m.account=(o->>'account')::uuid AND m.meton_user=(o->>'user')::uuid AND m.remote_user=(p_claim->>'remoteUser')::bigint
      AND m.source_marker=(p_claim->>'sourceMarker')::uuid AND o->>'environment'=p_env AND o->>'source'=p_source AND (o->>'epoch')::bigint=p_epoch
      AND u.role='user' AND u.status='active' AND u.deleted_at IS NULL AND u.restrict_public_groups
      AND u.email='meton-'||m.account::text||'@managed.invalid' FOR SHARE OF m,u;
    IF NOT FOUND THEN RAISE EXCEPTION 'original account unconfirmed' USING ERRCODE='55000'; END IF;
    IF op IS NULL OR binder IS NULL OR disp IS NULL OR sess IS NULL OR family IS NULL OR gen IS NULL OR gen<1 OR
        '00000000-0000-0000-0000-000000000000'::uuid IN (op,binder,disp,sess,family) OR
        coalesce((p_claim->>'securityVersion')::bigint,0)<1 OR coalesce((p_claim->>'identityRecoveryVersion')::bigint,0)<1 OR
        p_secret IS NULL OR p_secret !~ '^sk-[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid key reference' USING ERRCODE='22023'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(creation.source_marker::text||':'||sess::text,0));
    stamp:=clock_timestamp();ending:=stamp+interval '24 hours';
    IF p_deadline IS NULL OR p_deadline<=stamp OR p_deadline>stamp+interval '30 seconds' THEN RAISE EXCEPTION 'permit expired' USING ERRCODE='55000'; END IF;
    SELECT * INTO prior FROM public.meton_managed_keys WHERE operation=op;
    IF FOUND THEN
        IF prior.claim IS DISTINCT FROM p_claim THEN RAISE EXCEPTION 'key operation conflict' USING ERRCODE='23505'; END IF;
        RETURN false;
    END IF;
    -- 已经有同一会话的可用原 Key 时不能以换操作号再签一个。旧代次也不能在新代次以后写入。
    IF EXISTS (SELECT FROM public.meton_managed_keys x JOIN public.api_keys k ON x.remote_key=k.id
               WHERE x.source_marker=creation.source_marker AND x.session_id=sess
               AND (x.generation>=gen OR (k.status='active' AND k.deleted_at IS NULL AND k.expires_at>stamp))) THEN
        RAISE EXCEPTION 'session key requires prior closure' USING ERRCODE='23505'; END IF;
    INSERT INTO public.api_keys(user_id,key,name,status,created_at,updated_at,expires_at)
       VALUES(creation.remote_user,p_secret,'meton-'||replace(op::text,'-',''),'active',stamp,stamp,ending) RETURNING id INTO kid;
    IF NOT EXISTS (SELECT FROM public.api_keys WHERE id=kid AND user_id=creation.remote_user AND key=p_secret AND status='active' AND expires_at=ending
       AND created_at=stamp AND group_id IS NULL AND deleted_at IS NULL) THEN RAISE EXCEPTION 'unexpected key data' USING ERRCODE='23514'; END IF;
    INSERT INTO public.meton_managed_keys VALUES(op,binder,disp,creation.source_marker,creation.meton_user,sess,gen,p_claim,gen_random_uuid(),kid,stamp,ending,
        encode(sha256(convert_to(p_secret,'UTF8')),'hex'));
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION meton_issue_managed_key(text,text,bigint,jsonb,timestamptz,text) FROM PUBLIC;

-- 迁移与未来撤销可以改变原生 Key 的状态，不能改写最初签发记录或把它挂到新会话。
CREATE FUNCTION keep_meton_key_origin() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'key origin is immutable' USING ERRCODE='23514'; END $$;
CREATE TRIGGER keep_meton_key_origin BEFORE UPDATE OR DELETE ON meton_managed_keys FOR EACH ROW EXECUTE FUNCTION keep_meton_key_origin();
