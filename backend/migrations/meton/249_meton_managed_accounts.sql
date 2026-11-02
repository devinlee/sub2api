-- 专用托管实例由运维先在独立控制面固定代次，再显式装入写栅栏。空表表示关闭；迁移不创建用户或开放写入。
CREATE TABLE meton_managed_fence (
    singleton boolean PRIMARY KEY CHECK (singleton),
    environment varchar(120) NOT NULL, source varchar(120) NOT NULL,
    epoch bigint NOT NULL CHECK (epoch > 0), enabled boolean NOT NULL DEFAULT false
);
CREATE TABLE meton_managed_creations (
    operation uuid PRIMARY KEY, environment varchar(120) NOT NULL, source varchar(120) NOT NULL,
    meton_user uuid NOT NULL, account uuid NOT NULL, dispatch uuid NOT NULL, epoch bigint NOT NULL CHECK(epoch>0),
    remote_user bigint NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
    source_marker uuid NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(environment,source,meton_user), UNIQUE(environment,source,account), UNIQUE(environment,source,dispatch)
);

-- 事务成功才同时存在原创建和原用户。其他原操作即使提供同一个邮箱／用户／数值 ID 也不能认领。
CREATE FUNCTION meton_claim_managed_account(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_operation uuid,p_dispatch uuid)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE item public.meton_managed_creations%ROWTYPE; uid bigint; marker uuid; mail text;
BEGIN
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'managed source unavailable' USING ERRCODE='55000'; END IF;
    IF p_user IS NULL OR p_account IS NULL OR p_operation IS NULL OR p_dispatch IS NULL OR
        '00000000-0000-0000-0000-000000000000'::uuid IN (p_user,p_account,p_operation,p_dispatch) THEN
        RAISE EXCEPTION 'invalid managed reference' USING ERRCODE='22023';
    END IF;
    -- 同一用户串行，异用户冒领同一操作／对象由唯一约束拒绝并回滚本事务里刚建的用户。
    PERFORM pg_advisory_xact_lock(hashtextextended(p_env||':'||p_source||':'||p_user::text, 0));
    SELECT * INTO item FROM public.meton_managed_creations WHERE operation=p_operation;
    IF FOUND THEN
        IF ROW(item.environment,item.source,item.epoch,item.meton_user,item.account,item.dispatch)
            IS DISTINCT FROM ROW(p_env,p_source,p_epoch,p_user,p_account,p_dispatch) THEN
            RAISE EXCEPTION 'managed creation conflict' USING ERRCODE='23505'; END IF;
        RETURN;
    END IF;
    mail := 'meton-'||p_account::text||'@managed.invalid';
    IF EXISTS (SELECT FROM public.users WHERE lower(email)=mail) THEN RAISE EXCEPTION 'original object requires inspection' USING ERRCODE='23505'; END IF;
    marker := gen_random_uuid();
    -- 不发 Web 凭据。无可验证的原生密码；余额、并发、公开分组显式给定，不调用注册赠送、订阅或邀请逻辑。
    INSERT INTO public.users(email,password_hash,role,balance,concurrency,status,restrict_public_groups)
        VALUES(mail,'!meton-managed','user',0,1,'active',true) RETURNING id INTO uid;
    -- 数据库触发器或误配的额外行为也不能伪装成零权益回执。只检查建号时的事实，后续消费不改原回执。
    IF NOT EXISTS (SELECT FROM public.users WHERE id=uid AND balance=0 AND role='user' AND status='active'
        AND password_hash='!meton-managed' AND email=mail AND restrict_public_groups AND concurrency=1)
        OR EXISTS (SELECT FROM public.api_keys WHERE user_id=uid)
        OR EXISTS (SELECT FROM public.user_subscriptions WHERE user_id=uid)
        OR EXISTS (SELECT FROM public.user_allowed_groups WHERE user_id=uid) THEN
        RAISE EXCEPTION 'unexpected managed entitlement' USING ERRCODE='23514';
    END IF;
    INSERT INTO public.meton_managed_creations(operation,environment,source,meton_user,account,dispatch,epoch,remote_user,source_marker)
        VALUES(p_operation,p_env,p_source,p_user,p_account,p_dispatch,p_epoch,uid,marker);
END $$;
REVOKE ALL ON FUNCTION meton_claim_managed_account(text,text,bigint,uuid,uuid,uuid,uuid) FROM PUBLIC;
