-- 原用户、资金出生标识和所有历史 Key 不换归属。受限维护动作只在离线、写栅栏关闭的候选库内执行。
CREATE TABLE meton_recovery_successions (
    environment text NOT NULL, source text NOT NULL, meton_user uuid NOT NULL, restore_id uuid NOT NULL,
    previous_epoch bigint NOT NULL CHECK(previous_epoch>0), next_epoch bigint NOT NULL CHECK(next_epoch>previous_epoch),
    account uuid NOT NULL, operation uuid NOT NULL REFERENCES meton_managed_creations(operation), dispatch uuid NOT NULL,
    remote_user bigint NOT NULL, source_marker uuid NOT NULL, evidence text NOT NULL CHECK(evidence ~ '^[0-9a-f]{64}$'),
    PRIMARY KEY(environment,source,meton_user,restore_id), UNIQUE(source_marker,previous_epoch), UNIQUE(source_marker,next_epoch)
);
REVOKE ALL ON meton_recovery_successions FROM PUBLIC;

CREATE FUNCTION meton_keep_recovery_origin() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF (to_jsonb(NEW)-'epoch') IS DISTINCT FROM (to_jsonb(OLD)-'epoch') OR NEW.epoch<>OLD.epoch AND NOT (
        NEW.epoch>OLD.epoch AND current_user=pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid='public.meton_managed_creations'::regclass))
        AND EXISTS(SELECT FROM public.meton_recovery_successions WHERE source_marker=OLD.source_marker AND previous_epoch=OLD.epoch AND next_epoch=NEW.epoch)
    ) THEN RAISE EXCEPTION 'managed origin is immutable' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_keep_recovery_origin BEFORE UPDATE ON meton_managed_creations FOR EACH ROW EXECUTE FUNCTION meton_keep_recovery_origin();

CREATE FUNCTION meton_recover_original(p_env text,p_user uuid,p_restore uuid,p_previous bigint,p_next bigint,p_source text,
        p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_evidence text)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE a public.meton_managed_creations%ROWTYPE; receipt public.meton_recovery_successions%ROWTYPE;
BEGIN
    IF current_user<>pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid='public.meton_managed_creations'::regclass)) THEN
        RAISE EXCEPTION 'offline schema owner required' USING ERRCODE='42501'; END IF;
    SELECT * INTO STRICT a FROM public.meton_managed_creations WHERE environment=p_env AND source=p_source AND meton_user=p_user FOR UPDATE;
    IF p_restore IS NULL OR p_restore='00000000-0000-0000-0000-000000000000'::uuid OR p_next IS NULL OR p_previous IS NULL OR p_next<=p_previous
        OR p_evidence IS NULL OR p_evidence !~ '^[0-9a-f]{64}$' OR ROW(a.account,a.operation,a.dispatch,a.remote_user,a.source_marker)
           IS DISTINCT FROM ROW(p_account,p_creation,p_dispatch,p_remote,p_marker) THEN RAISE EXCEPTION 'recovery scope mismatch'; END IF;
    SELECT * INTO receipt FROM public.meton_recovery_successions WHERE source_marker=p_marker AND restore_id=p_restore;
    IF FOUND THEN
        IF ROW(receipt.previous_epoch,receipt.next_epoch,receipt.evidence) IS DISTINCT FROM ROW(p_previous,p_next,p_evidence) THEN RAISE EXCEPTION 'recovery conflict'; END IF;
        RETURN;
    END IF;
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND NOT enabled AND environment=p_env AND source=p_source AND epoch=p_previous FOR UPDATE;
    IF NOT FOUND OR a.epoch<>p_previous THEN RAISE EXCEPTION 'source must be fenced'; END IF;
    IF NOT EXISTS (SELECT FROM public.users u JOIN public.meton_s1_funds_births b ON b.remote_user=u.id AND b.operation=p_creation
        WHERE u.id=p_remote AND u.status='active' AND u.role='user' AND u.restrict_public_groups AND u.deleted_at IS NULL
          AND u.password_hash='!meton-managed' AND u.email='meton-'||p_account::text||'@managed.invalid')
        OR EXISTS (SELECT FROM public.api_keys k WHERE k.user_id=p_remote AND NOT EXISTS
            (SELECT FROM public.meton_managed_keys x WHERE x.remote_key=k.id AND x.source_marker=p_marker))
        OR EXISTS (SELECT FROM public.meton_managed_keys x WHERE x.source_marker=p_marker AND NOT EXISTS (
            SELECT FROM public.api_keys k JOIN public.meton_managed_key_retirements r ON r.remote_key=k.id
            JOIN public.meton_managed_session_closures c ON c.source_marker=x.source_marker AND c.session_id=x.session_id
            WHERE k.id=x.remote_key AND k.user_id=p_remote AND k.status='inactive' AND k.created_at=x.created_at AND k.expires_at=x.expires_at
              AND encode(sha256(convert_to(k.key,'UTF8')),'hex')=x.material_sha256 AND r.operation=x.operation AND r.key_marker=x.key_marker)) THEN
        RAISE EXCEPTION 'original keys unconfirmed'; END IF;
    INSERT INTO public.meton_recovery_successions VALUES(p_env,p_source,p_user,p_restore,p_previous,p_next,p_account,p_creation,p_dispatch,p_remote,p_marker,p_evidence);
    UPDATE public.meton_managed_creations SET epoch=p_next WHERE operation=p_creation;
END $$;
REVOKE ALL ON FUNCTION meton_recover_original(text,uuid,uuid,bigint,bigint,text,uuid,uuid,uuid,bigint,uuid,text) FROM PUBLIC;

-- 数字编号和原密钥材料即使在旧快照里仍能匹配，也不能跨签发代次验权。
CREATE OR REPLACE FUNCTION meton_current_key(p_env text,p_source text,p_epoch bigint,p_remote bigint,p_user bigint,p_hash text)
RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,public AS $$
    SELECT EXISTS(SELECT FROM public.meton_managed_fence f JOIN public.meton_managed_creations m
        ON m.environment=f.environment AND m.source=f.source AND m.epoch=f.epoch
        JOIN public.meton_managed_keys x ON x.source_marker=m.source_marker AND x.claim->'origin'->>'epoch'=f.epoch::text
        JOIN public.api_keys k ON k.id=x.remote_key AND k.user_id=m.remote_user
        JOIN public.users u ON u.id=k.user_id AND u.status='active' AND u.role='user' AND u.restrict_public_groups AND u.deleted_at IS NULL
        WHERE f.singleton AND f.enabled AND f.environment=p_env AND f.source=p_source AND f.epoch=p_epoch AND x.remote_key=p_remote AND k.user_id=p_user
          AND k.status='active' AND k.deleted_at IS NULL AND k.created_at=x.created_at AND k.expires_at=x.expires_at AND x.expires_at>statement_timestamp()
          AND x.material_sha256=p_hash AND encode(sha256(convert_to(k.key,'UTF8')),'hex')=p_hash
          AND NOT EXISTS (SELECT FROM public.meton_managed_key_retirements r WHERE r.operation=x.operation));
$$;
