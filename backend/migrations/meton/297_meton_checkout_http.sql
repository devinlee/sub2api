-- 三个入口各有一把原生管理 Key 和一个只执行本入口的数据库角色。
-- 运维只在当前来源代次追加换钥事实；撤销后旧部署不能靠还原配置重新选择旧 Key。
CREATE TABLE meton_ledger.checkout_http_keys (
    environment text NOT NULL, source text NOT NULL, epoch bigint NOT NULL CHECK (epoch>0),
    action text NOT NULL CHECK (action IN ('issue','redeem','status')), generation bigint NOT NULL CHECK (generation>0),
    key_id varchar(24) PRIMARY KEY REFERENCES public.scoped_admin_api_keys(id),
    UNIQUE (environment,source,epoch,action,generation)
);
CREATE FUNCTION meton_ledger.check_checkout_key_generation() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=NEW.environment
        AND source=NEW.source AND epoch=NEW.epoch FOR UPDATE;
    IF NOT FOUND OR NEW.generation<>(SELECT coalesce(max(generation),0)+1 FROM meton_ledger.checkout_http_keys
        WHERE (environment,source,epoch,action)=(NEW.environment,NEW.source,NEW.epoch,NEW.action)) THEN
        RAISE EXCEPTION 'checkout control generation unavailable' USING ERRCODE='42501'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER checkout_key_generation BEFORE INSERT ON meton_ledger.checkout_http_keys
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_checkout_key_generation();
CREATE TRIGGER checkout_key_immutable BEFORE UPDATE OR DELETE ON meton_ledger.checkout_http_keys
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.checkout_http_keys ENABLE ALWAYS TRIGGER checkout_key_generation;
ALTER TABLE meton_ledger.checkout_http_keys ENABLE ALWAYS TRIGGER checkout_key_immutable;
REVOKE ALL ON meton_ledger.checkout_http_keys FROM PUBLIC;

-- HTTP 身份证明覆盖实际请求体的字节和截止毫秒；来源只接受自己的当代 Key、原生管理员和当前策略。
CREATE FUNCTION meton_ledger.apply_checkout_http(p_action text,p_wire text,p_key text,p_creator bigint,p_revision timestamptz,
    p_until_ms bigint,p_witness text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE q jsonb; orig jsonb; desk jsonb; browser jsonb; verifier text; expires timestamptz;
    latest text; deadline timestamptz; result text; sid uuid; current_epoch bigint; key_policy jsonb;
BEGIN
    IF num_nulls(p_action,p_wire,p_key,p_creator,p_revision,p_until_ms,p_witness)>0
        OR p_action NOT IN ('issue','redeem','status') OR octet_length(p_wire)>8192 OR p_key !~ '^[0-9a-f]{24}$'
        OR p_creator<1 OR p_witness !~ '^[0-9a-f]{64}$' OR p_until_ms NOT BETWEEN
            floor(extract(epoch FROM clock_timestamp())*1000)::bigint+1 AND floor(extract(epoch FROM clock_timestamp())*1000)::bigint+5000
        OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin'
        OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_ledger','CREATE')
        OR current_setting('transaction_isolation')<>'read committed'
        OR (current_setting('transaction_read_only')='on')<>(p_action='status')
        OR current_setting('statement_timeout')::interval NOT BETWEEN interval '1 millisecond' AND interval '5 seconds' THEN
        RAISE EXCEPTION 'checkout authority unavailable' USING ERRCODE='42501'; END IF;
    q:=p_wire::jsonb; orig:=q->'origin'; desk:=q->'desktop'; browser:=q->'browser'; sid:=(q->>'intent')::uuid;
    current_epoch:=(orig->>'epoch')::bigint; deadline:=to_timestamp(p_until_ms::double precision/1000);
    IF q->'version' IS DISTINCT FROM '1'::jsonb OR (q->>'validUntil') IS NULL OR sid IS NULL
        OR NOT isfinite((q->>'validUntil')::timestamptz) OR (q->>'validUntil')::timestamptz<deadline
        OR (q->>'validUntil')::timestamptz>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'checkout admission unavailable' USING ERRCODE='42501'; END IF;
    -- 写事务先锁来源栅栏，再锁原生权限行；换钥、停用或退出和本次交接按同一事实排序。
    IF p_action<>'status' THEN
        PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=orig->>'environment'
            AND source=orig->>'source' AND epoch=current_epoch FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION 'checkout source unavailable' USING ERRCODE='42501'; END IF;
        PERFORM 1 FROM public.scoped_admin_api_keys k JOIN public.users u ON u.id=k.created_by
            WHERE k.id=p_key AND u.id=p_creator FOR SHARE OF k,u;
        IF NOT FOUND THEN RAISE EXCEPTION 'checkout authority unavailable' USING ERRCODE='42501'; END IF;
    END IF;
    SELECT key_id INTO latest FROM meton_ledger.checkout_http_keys
        WHERE environment=orig->>'environment' AND source=orig->>'source' AND epoch=current_epoch AND action=p_action
        ORDER BY generation DESC LIMIT 1;
    SELECT k.key_hash,k.expires_at,k.policy INTO verifier,expires,key_policy
        FROM public.scoped_admin_api_keys k JOIN public.users u ON u.id=k.created_by
        WHERE k.id=p_key AND u.id=p_creator AND k.updated_at=p_revision AND k.enabled AND k.revoked_at IS NULL
            AND k.deleted_at IS NULL AND u.role='admin' AND u.status='active' AND u.deleted_at IS NULL;
    IF NOT FOUND OR latest IS DISTINCT FROM p_key OR clock_timestamp()>=deadline OR expires<deadline
        OR key_policy->'global_permissions' IS DISTINCT FROM jsonb_build_array('meton.checkout.'||p_action)
        OR coalesce(key_policy->'rules','[]'::jsonb) NOT IN ('[]'::jsonb,'null'::jsonb)
        OR p_witness IS DISTINCT FROM encode(sha256(convert_to(concat_ws('|','meton.checkout.http.v1',p_action,p_key,
            p_creator,p_until_ms,encode(sha256(convert_to(p_wire,'UTF8')),'hex'),verifier),'UTF8')),'hex') THEN
        RAISE EXCEPTION 'checkout authority unavailable' USING ERRCODE='42501'; END IF;
    orig:=(orig-'sourceMarker'-'remoteUser')||jsonb_build_object('source_marker',orig->'sourceMarker','remote_user',orig->'remoteUser');
    desk:=(desk-'securityVersion'-'recoveryVersion')||jsonb_build_object('security_version',desk->'securityVersion','recovery_version',desk->'recoveryVersion');
    CASE p_action
        WHEN 'issue' THEN result:=meton_ledger.issue_checkout_handoff(orig,desk,sid,decode(q->>'challengeHash','base64'),q->>'returnTarget',deadline);
        WHEN 'redeem' THEN
            browser:=(browser-'securityVersion'-'recoveryVersion')||jsonb_build_object('security_version',browser->'securityVersion','recovery_version',browser->'recoveryVersion');
            result:=meton_ledger.redeem_checkout_handoff(orig,desk,browser,sid,decode(q->>'challenge','base64'),decode(q->>'webProof','base64'),deadline);
        WHEN 'status' THEN result:=meton_ledger.read_checkout_handoff(orig,desk,sid,deadline);
    END CASE;
    IF clock_timestamp()>=deadline THEN RAISE EXCEPTION 'checkout admission expired' USING ERRCODE='55000'; END IF;
    RETURN result;
END $$;

CREATE FUNCTION meton_ledger.http_checkout_issue(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_ledger.apply_checkout_http('issue',$1,$2,$3,$4,$5,$6) $$;
CREATE FUNCTION meton_ledger.http_checkout_redeem(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_ledger.apply_checkout_http('redeem',$1,$2,$3,$4,$5,$6) $$;
CREATE FUNCTION meton_ledger.http_checkout_status(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_ledger.apply_checkout_http('status',$1,$2,$3,$4,$5,$6) $$;
REVOKE ALL ON FUNCTION meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text),
    meton_ledger.check_checkout_key_generation(),
    meton_ledger.http_checkout_issue(text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_checkout_redeem(text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_checkout_status(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
