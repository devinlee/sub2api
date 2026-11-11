-- 托管收银台只接原账号的单笔充值，既不创建来源用户，也不签发 sub2api 通用 JWT。
CREATE TABLE meton_ledger.checkout_handoffs (
    intent_id uuid PRIMARY KEY,
    source_marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker),
    origin jsonb NOT NULL, desktop jsonb NOT NULL,
    return_target text NOT NULL CHECK (return_target='account.credits'),
    challenge_hash bytea NOT NULL UNIQUE CHECK (octet_length(challenge_hash)=32),
    issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL CHECK (expires_at=issued_at+interval '2 minutes'),
    browser jsonb, web_hash bytea UNIQUE CHECK (octet_length(web_hash)=32),
    redeemed_at timestamptz, web_expires_at timestamptz,
    CHECK ((browser IS NULL AND web_hash IS NULL AND redeemed_at IS NULL AND web_expires_at IS NULL)
        OR (browser IS NOT NULL AND web_hash IS NOT NULL AND redeemed_at IS NOT NULL AND web_expires_at IS NOT NULL
        AND redeemed_at>=issued_at AND redeemed_at<expires_at AND web_expires_at=redeemed_at+interval '15 minutes'))
);

-- 原范围由业务侧从当次 Identity 权威和原账号映射构造。前台不能提供本函数的调用资格。
-- 与原退出事务使用相同会话锁；等待后在 READ COMMITTED 重读关闭事实，陈旧快照及过期复验一律拒绝。
CREATE FUNCTION meton_ledger.check_checkout_scope(p_origin jsonb,p_desktop jsonb,p_browser jsonb,p_until timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; who jsonb; sid uuid; sessions uuid[];
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR pg_is_in_recovery()
        OR current_setting('session_replication_role')<>'origin' OR p_desktop IS NULL
        OR p_until IS NULL OR NOT isfinite(p_until) OR p_until<=clock_timestamp() OR p_until>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'checkout admission unavailable' USING ERRCODE='55000'; END IF;
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_origin->>'environment'
        AND source=p_origin->>'source' AND epoch=(p_origin->>'epoch')::bigint FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'checkout source closed' USING ERRCODE='55000'; END IF;
    SELECT * INTO m FROM public.meton_managed_creations WHERE source_marker=(p_origin->>'source_marker')::uuid FOR SHARE;
    IF NOT FOUND OR p_origin IS DISTINCT FROM jsonb_build_object(
        'environment',m.environment,'source',m.source,'epoch',m.epoch,'user',m.meton_user,'account',m.account,
        'creation',m.operation,'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker) THEN
        RAISE EXCEPTION 'checkout original mismatch' USING ERRCODE='42501'; END IF;
    FOREACH who IN ARRAY ARRAY[p_desktop,p_browser] LOOP
        CONTINUE WHEN who IS NULL;
        sid:=(who->>'session')::uuid;
        IF sid IS NULL OR (who->>'family')::uuid IS NULL OR
            '00000000-0000-0000-0000-000000000000'::uuid IN (sid,(who->>'family')::uuid) OR
            coalesce((who->>'security_version')::bigint,0)<1 OR coalesce((who->>'recovery_version')::bigint,0)<1 OR
            who IS DISTINCT FROM jsonb_build_object('user',m.meton_user,'session',sid,'family',(who->>'family')::uuid,
                'security_version',(who->>'security_version')::bigint,'recovery_version',(who->>'recovery_version')::bigint) THEN
            RAISE EXCEPTION 'checkout subject mismatch' USING ERRCODE='42501'; END IF;
        sessions:=array_append(sessions,sid);
    END LOOP;
    IF p_browser IS NOT NULL AND (p_browser->>'security_version',p_browser->>'recovery_version') IS DISTINCT FROM
        (p_desktop->>'security_version',p_desktop->>'recovery_version') THEN
        RAISE EXCEPTION 'checkout account version changed' USING ERRCODE='42501'; END IF;
    FOR sid IN SELECT DISTINCT s FROM unnest(sessions) s ORDER BY s LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(m.source_marker::text||':'||sid::text,0));
    END LOOP;
    PERFORM 1 FROM public.users WHERE id=m.remote_user AND role='user' AND status='active' AND deleted_at IS NULL
        AND password_hash='!meton-managed' FOR SHARE;
    IF NOT FOUND OR EXISTS(SELECT FROM public.meton_managed_session_closures WHERE source_marker=m.source_marker AND session_id=ANY(sessions))
        OR p_until<=clock_timestamp() THEN RAISE EXCEPTION 'checkout authority expired' USING ERRCODE='55000'; END IF;
    RETURN m.source_marker;
END $$;

CREATE FUNCTION meton_ledger.issue_checkout_handoff(p_origin jsonb,p_desktop jsonb,p_intent uuid,p_hash bytea,
    p_return text,p_until timestamptz)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid; prior meton_ledger.checkout_handoffs%ROWTYPE; stamp timestamptz;
BEGIN
    marker:=meton_ledger.check_checkout_scope(p_origin,p_desktop,NULL,p_until);
    IF p_intent IS NULL OR p_intent='00000000-0000-0000-0000-000000000000' OR p_hash IS NULL OR octet_length(p_hash)<>32
        OR p_return IS DISTINCT FROM 'account.credits' THEN RAISE EXCEPTION 'invalid purchase intent' USING ERRCODE='22023'; END IF;
    stamp:=clock_timestamp();
    INSERT INTO meton_ledger.checkout_handoffs(intent_id,source_marker,origin,desktop,challenge_hash,return_target,issued_at,expires_at)
        VALUES(p_intent,marker,p_origin,p_desktop,p_hash,p_return,stamp,stamp+interval '2 minutes') ON CONFLICT(intent_id) DO NOTHING;
    SELECT * INTO STRICT prior FROM meton_ledger.checkout_handoffs WHERE intent_id=p_intent FOR SHARE;
    IF (prior.source_marker,prior.origin,prior.desktop,prior.challenge_hash,prior.return_target)
        IS DISTINCT FROM (marker,p_origin,p_desktop,p_hash,p_return) THEN
        RAISE EXCEPTION 'purchase intent conflict' USING ERRCODE='23505'; END IF;
    IF p_until<=clock_timestamp() THEN RAISE EXCEPTION 'checkout admission expired' USING ERRCODE='55000'; END IF;
    IF prior.redeemed_at IS NOT NULL THEN RETURN 'redeemed'; END IF;
    RETURN CASE WHEN prior.expires_at>clock_timestamp() THEN 'issued' ELSE 'expired' END;
END $$;

-- 浏览器和桌面必须分别为当前登录的同一主体。响应丢失只能用原浏览器、原随机材料查询同笔兑换。
CREATE FUNCTION meton_ledger.redeem_checkout_handoff(p_origin jsonb,p_desktop jsonb,p_browser jsonb,p_intent uuid,
    p_challenge bytea,p_web bytea,p_until timestamptz)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid; prior meton_ledger.checkout_handoffs%ROWTYPE; stamp timestamptz;
BEGIN
    IF p_browser IS NULL OR p_challenge IS NULL OR p_web IS NULL OR octet_length(p_challenge)<>32 OR octet_length(p_web)<>32
        OR p_challenge=p_web THEN RAISE EXCEPTION 'invalid checkout proof' USING ERRCODE='42501'; END IF;
    marker:=meton_ledger.check_checkout_scope(p_origin,p_desktop,p_browser,p_until);
    SELECT * INTO prior FROM meton_ledger.checkout_handoffs WHERE intent_id=p_intent AND source_marker=marker FOR UPDATE;
    IF NOT FOUND OR (prior.origin,prior.desktop,prior.challenge_hash) IS DISTINCT FROM (p_origin,p_desktop,sha256(p_challenge)) THEN
        RAISE EXCEPTION 'checkout original denied' USING ERRCODE='42501'; END IF;
    stamp:=clock_timestamp();
    IF stamp>=p_until THEN RAISE EXCEPTION 'checkout revalidation expired' USING ERRCODE='55000'; END IF;
    IF prior.redeemed_at IS NOT NULL THEN
        IF (prior.browser,prior.web_hash) IS DISTINCT FROM (p_browser,sha256(p_web)) THEN
            RAISE EXCEPTION 'checkout proof already consumed' USING ERRCODE='42501'; END IF;
        RETURN CASE WHEN stamp<prior.web_expires_at THEN 'redeemed' ELSE 'expired' END;
    END IF;
    IF stamp>=prior.expires_at THEN RETURN 'expired'; END IF;
    UPDATE meton_ledger.checkout_handoffs SET browser=p_browser,web_hash=sha256(p_web),redeemed_at=stamp,web_expires_at=stamp+interval '15 minutes'
        WHERE intent_id=p_intent;
    RETURN 'redeemed';
END $$;

-- 后续新下单必须在同一来源事务内复核此用途、原设备和浏览器；旧订单的资金核对独立沿原单。
CREATE FUNCTION meton_ledger.authorize_checkout_order(p_origin jsonb,p_desktop jsonb,p_browser jsonb,p_intent uuid,
    p_web bytea,p_until timestamptz)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid; expiry timestamptz;
BEGIN
    IF p_browser IS NULL OR p_web IS NULL OR octet_length(p_web)<>32 THEN RAISE EXCEPTION 'checkout proof required' USING ERRCODE='42501'; END IF;
    marker:=meton_ledger.check_checkout_scope(p_origin,p_desktop,p_browser,p_until);
    SELECT web_expires_at INTO expiry FROM meton_ledger.checkout_handoffs
        WHERE intent_id=p_intent AND source_marker=marker AND origin=p_origin AND desktop=p_desktop
        AND browser=p_browser AND web_hash=sha256(p_web) FOR SHARE;
    IF NOT FOUND OR least(expiry,p_until)<=clock_timestamp() THEN RAISE EXCEPTION 'checkout session unavailable' USING ERRCODE='42501'; END IF;
    RETURN true;
END $$;
-- 单独只读查询已发原操作；不兑换、不延长时间、不返回任何秘密。错范围与查无均不交出他人记录。
CREATE FUNCTION meton_ledger.read_checkout_handoff(p_origin jsonb,p_desktop jsonb,p_intent uuid,p_until timestamptz)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE prior meton_ledger.checkout_handoffs%ROWTYPE; stamp timestamptz;
BEGIN
    stamp:=clock_timestamp();
    IF current_setting('transaction_isolation')<>'read committed' OR current_setting('transaction_read_only')<>'on'
        OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR p_until IS NULL OR NOT isfinite(p_until)
        OR p_until<=stamp OR p_until>stamp+interval '30 seconds' THEN
        RAISE EXCEPTION 'checkout query admission unavailable' USING ERRCODE='55000'; END IF;
    IF NOT EXISTS (SELECT FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_origin->>'environment'
        AND source=p_origin->>'source' AND epoch=(p_origin->>'epoch')::bigint) THEN
        RAISE EXCEPTION 'checkout source closed' USING ERRCODE='55000'; END IF;
    SELECT h.* INTO prior FROM meton_ledger.checkout_handoffs h
        JOIN public.meton_managed_creations m ON m.source_marker=h.source_marker
        JOIN public.users u ON u.id=m.remote_user
        WHERE h.intent_id=p_intent AND h.origin=p_origin AND h.desktop=p_desktop AND m.epoch=(p_origin->>'epoch')::bigint
        AND m.operation=(p_origin->>'creation')::uuid AND u.status='active' AND u.deleted_at IS NULL;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF EXISTS (SELECT FROM public.meton_managed_session_closures WHERE source_marker=prior.source_marker
        AND session_id IN ((prior.desktop->>'session')::uuid,(prior.browser->>'session')::uuid)) THEN RETURN 'revoked'; END IF;
    IF clock_timestamp()>=p_until THEN RAISE EXCEPTION 'checkout query admission expired' USING ERRCODE='55000'; END IF;
    IF prior.redeemed_at IS NOT NULL THEN RETURN CASE WHEN prior.web_expires_at>clock_timestamp() THEN 'redeemed' ELSE 'expired' END; END IF;
    RETURN CASE WHEN prior.expires_at>clock_timestamp() THEN 'issued' ELSE 'expired' END;
END $$;
REVOKE ALL ON meton_ledger.checkout_handoffs FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.check_checkout_scope(jsonb,jsonb,jsonb,timestamptz),
    meton_ledger.issue_checkout_handoff(jsonb,jsonb,uuid,bytea,text,timestamptz),
    meton_ledger.redeem_checkout_handoff(jsonb,jsonb,jsonb,uuid,bytea,bytea,timestamptz),
    meton_ledger.authorize_checkout_order(jsonb,jsonb,jsonb,uuid,bytea,timestamptz),
    meton_ledger.read_checkout_handoff(jsonb,jsonb,uuid,timestamptz) FROM PUBLIC;
