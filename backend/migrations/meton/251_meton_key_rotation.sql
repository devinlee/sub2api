-- 已提交的原停用是独立事实，不能把查询查无、数值编号或本地到期代替该事实。
CREATE TABLE meton_managed_key_retirements (
    operation uuid PRIMARY KEY REFERENCES meton_managed_keys(operation) ON DELETE RESTRICT,
    key_marker uuid NOT NULL UNIQUE,remote_key bigint NOT NULL UNIQUE,retired_at timestamptz NOT NULL
);
CREATE TRIGGER keep_meton_key_retirement BEFORE UPDATE OR DELETE ON meton_managed_key_retirements
    FOR EACH ROW EXECUTE FUNCTION keep_meton_key_origin();

CREATE FUNCTION meton_retire_key_for_rotation(p_env text,p_source text,p_epoch bigint,p_claim jsonb,p_marker uuid,p_key bigint,p_deadline timestamptz)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE target public.meton_managed_keys%ROWTYPE; original public.meton_managed_creations%ROWTYPE; stamp timestamptz;
BEGIN
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'source fenced' USING ERRCODE='55000'; END IF;
    SELECT x.* INTO target FROM public.meton_managed_keys x WHERE x.operation=(p_claim->>'operation')::uuid FOR UPDATE;
    IF NOT FOUND OR target.claim IS DISTINCT FROM p_claim OR target.key_marker IS DISTINCT FROM p_marker OR target.remote_key IS DISTINCT FROM p_key THEN
        RAISE EXCEPTION 'original key mismatch' USING ERRCODE='23505'; END IF;
    SELECT * INTO original FROM public.meton_managed_creations WHERE source_marker=target.source_marker AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'original account unavailable' USING ERRCODE='55000'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(target.source_marker::text||':'||target.session_id::text,0));
    stamp:=clock_timestamp();
    IF p_deadline IS NULL OR p_deadline<=stamp OR p_deadline>stamp+interval '30 seconds' OR target.expires_at>stamp+interval '15 minutes' THEN
        RAISE EXCEPTION 'rotation not due or permit ended' USING ERRCODE='55000'; END IF;
    IF EXISTS (SELECT FROM public.meton_managed_key_retirements WHERE operation=target.operation AND key_marker=p_marker AND remote_key=p_key) THEN RETURN; END IF;
    UPDATE public.api_keys SET status='inactive',updated_at=stamp WHERE id=p_key AND user_id=original.remote_user AND created_at=target.created_at
        AND expires_at=target.expires_at AND deleted_at IS NULL AND status IN ('active','inactive') AND encode(sha256(convert_to(key,'UTF8')),'hex')=target.material_sha256;
    IF NOT FOUND THEN RAISE EXCEPTION 'native object unconfirmed' USING ERRCODE='55000'; END IF;
    INSERT INTO public.meton_managed_key_retirements VALUES(target.operation,p_marker,p_key,stamp);
END $$;
REVOKE ALL ON FUNCTION meton_retire_key_for_rotation(text,text,bigint,jsonb,uuid,bigint,timestamptz) FROM PUBLIC;

-- 同一会话的历史原对象需要来源的逐项停用证明。手动改原生状态、或恰好到期，都不能冒充这份证明。
CREATE FUNCTION require_prior_meton_key_retirement() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF EXISTS(SELECT FROM public.meton_managed_keys x LEFT JOIN public.meton_managed_key_retirements r ON r.operation=x.operation
              AND r.key_marker=x.key_marker AND r.remote_key=x.remote_key WHERE x.source_marker=NEW.source_marker AND x.session_id=NEW.session_id AND
              (x.generation>=NEW.generation OR r.operation IS NULL)) THEN RAISE EXCEPTION 'prior retirement unconfirmed' USING ERRCODE='55000'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER require_prior_meton_key_retirement BEFORE INSERT ON meton_managed_keys FOR EACH ROW EXECUTE FUNCTION require_prior_meton_key_retirement();

-- 专用构建的原生 Key 鉴权以当前写库为准，缓存过的活动行不能令已停用 Key 继续获得准入。
CREATE FUNCTION meton_current_key(p_env text,p_source text,p_epoch bigint,p_remote bigint,p_user bigint,p_hash text)
RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,public AS $$
    SELECT EXISTS(
        SELECT FROM public.meton_managed_fence f JOIN public.meton_managed_creations m
          ON m.environment=f.environment AND m.source=f.source AND m.epoch=f.epoch
        JOIN public.meton_managed_keys x ON x.source_marker=m.source_marker
        JOIN public.api_keys k ON k.id=x.remote_key AND k.user_id=m.remote_user
        JOIN public.users u ON u.id=k.user_id AND u.status='active' AND u.role='user' AND u.restrict_public_groups AND u.deleted_at IS NULL
        WHERE f.singleton AND f.enabled AND f.environment=p_env AND f.source=p_source AND f.epoch=p_epoch AND x.remote_key=p_remote AND k.user_id=p_user
          AND k.status='active' AND k.deleted_at IS NULL AND k.created_at=x.created_at AND k.expires_at=x.expires_at AND x.expires_at>statement_timestamp()
          AND x.material_sha256=p_hash AND encode(sha256(convert_to(k.key,'UTF8')),'hex')=p_hash
          AND NOT EXISTS (SELECT FROM public.meton_managed_key_retirements r WHERE r.operation=x.operation)
    );
$$;
REVOKE ALL ON FUNCTION meton_current_key(text,text,bigint,bigint,bigint,text) FROM PUBLIC;
