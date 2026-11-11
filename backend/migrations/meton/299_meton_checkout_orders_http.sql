-- 交接和订单共用同一认证、换代与撤销逻辑。三项订单用途有各自的原生 Key 和数据库角色。
ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order'));

CREATE OR REPLACE FUNCTION meton_ledger.apply_checkout_http(p_action text,p_wire text,p_key text,p_creator bigint,p_revision timestamptz,
    p_until_ms bigint,p_witness text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE q jsonb; orig jsonb; desk jsonb; web_subject jsonb; verifier text; expires timestamptz;
    latest text; deadline timestamptz; result text; sid uuid; current_epoch bigint; key_policy jsonb;
BEGIN
    IF num_nulls(p_action,p_wire,p_key,p_creator,p_revision,p_until_ms,p_witness)>0
        OR p_action NOT IN ('issue','redeem','status','quote','confirm','order') OR octet_length(p_wire)>8192 OR p_key !~ '^[0-9a-f]{24}$'
        OR p_creator<1 OR p_witness !~ '^[0-9a-f]{64}$' OR p_until_ms NOT BETWEEN
            floor(extract(epoch FROM clock_timestamp())*1000)::bigint+1 AND floor(extract(epoch FROM clock_timestamp())*1000)::bigint+5000
        OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin'
        OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_ledger','CREATE')
        OR current_setting('transaction_isolation')<>'read committed'
        OR (current_setting('transaction_read_only')='on')<>(p_action IN ('status','order'))
        OR current_setting('statement_timeout')::interval NOT BETWEEN interval '1 millisecond' AND interval '5 seconds' THEN
        RAISE EXCEPTION 'checkout authority unavailable' USING ERRCODE='42501'; END IF;
    q:=p_wire::jsonb; orig:=q->'origin'; desk:=q->'desktop'; web_subject:=q->'browser'; sid:=(q->>'intent')::uuid;
    current_epoch:=(orig->>'epoch')::bigint; deadline:=to_timestamp(p_until_ms::double precision/1000);
    IF q->'version' IS DISTINCT FROM '1'::jsonb OR (q->>'validUntil') IS NULL OR sid IS NULL
        OR NOT isfinite((q->>'validUntil')::timestamptz) OR (q->>'validUntil')::timestamptz<deadline
        OR (q->>'validUntil')::timestamptz>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'checkout admission unavailable' USING ERRCODE='42501'; END IF;
    -- 写事务先锁来源栅栏，再锁原生权限行；换钥、停用或退出和本次交接按同一事实排序。
    IF p_action NOT IN ('status','order') THEN
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
    IF web_subject IS NOT NULL THEN
        web_subject:=(web_subject-'securityVersion'-'recoveryVersion')||jsonb_build_object('security_version',web_subject->'securityVersion','recovery_version',web_subject->'recoveryVersion');
    END IF;
    CASE p_action
        WHEN 'issue' THEN result:=meton_ledger.issue_checkout_handoff(orig,desk,sid,decode(q->>'challengeHash','base64'),q->>'returnTarget',deadline);
        WHEN 'redeem' THEN
            result:=meton_ledger.redeem_checkout_handoff(orig,desk,web_subject,sid,decode(q->>'challenge','base64'),decode(q->>'webProof','base64'),deadline);
        WHEN 'quote', 'confirm' THEN
            IF p_action='quote' THEN
                IF (q->'selection') ? 'quote' THEN RAISE EXCEPTION 'unexpected quote' USING ERRCODE='22023'; END IF;
                result:=meton_ledger.quote_purchase(orig,desk,web_subject,sid,decode(q->>'webProof','base64'),
                    q#>>'{selection,product}',q#>>'{selection,channel}',q#>>'{selection,currency}',(q#>>'{selection,priceFen}')::bigint,deadline)::text;
            ELSE
                result:=meton_ledger.commit_purchase(orig,desk,web_subject,sid,decode(q->>'webProof','base64'),(q#>>'{selection,quote}')::uuid,
                    q#>>'{selection,product}',q#>>'{selection,channel}',q#>>'{selection,currency}',(q#>>'{selection,priceFen}')::bigint,deadline)::text;
            END IF;
        WHEN 'order' THEN
            -- 新登录可以查询本账号原单。资料由当前会话签发，不允许已退出设备或另一账号借用它。
            IF desk->>'user' IS DISTINCT FROM orig->>'user' OR (desk->>'session')::uuid IS NULL
                OR (desk->>'family')::uuid IS NULL OR coalesce((desk->>'security_version')::bigint,0)<1
                OR coalesce((desk->>'recovery_version')::bigint,0)<1 OR EXISTS(
                    SELECT FROM public.meton_managed_session_closures WHERE source_marker=(orig->>'source_marker')::uuid
                    AND session_id=(desk->>'session')::uuid) THEN
                RAISE EXCEPTION 'current purchase reader unavailable' USING ERRCODE='42501'; END IF;
            IF web_subject IS NOT NULL OR q ? 'webProof' THEN
                IF meton_ledger.read_checkout_handoff(orig,desk,sid,deadline) IS DISTINCT FROM 'redeemed'
                    OR NOT EXISTS(SELECT FROM meton_ledger.checkout_handoffs h WHERE h.intent_id=sid AND h.origin=orig
                        AND h.desktop=desk AND h.browser=web_subject AND h.web_hash=sha256(decode(q->>'webProof','base64'))
                        AND h.web_expires_at>clock_timestamp()) THEN
                    RAISE EXCEPTION 'original cashier session unavailable' USING ERRCODE='42501'; END IF;
            END IF;
            result:=meton_ledger.read_original_purchase(orig,sid,deadline)::text;
        WHEN 'status' THEN result:=meton_ledger.read_checkout_handoff(orig,desk,sid,deadline);
    END CASE;
    IF clock_timestamp()>=deadline THEN RAISE EXCEPTION 'checkout admission expired' USING ERRCODE='55000'; END IF;
    RETURN result;
END $$;

CREATE FUNCTION meton_ledger.http_checkout_quote(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_ledger.apply_checkout_http('quote',$1,$2,$3,$4,$5,$6) $$;
REVOKE ALL ON FUNCTION meton_ledger.http_checkout_quote(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
CREATE FUNCTION meton_ledger.http_checkout_confirm(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_ledger.apply_checkout_http('confirm',$1,$2,$3,$4,$5,$6) $$;
REVOKE ALL ON FUNCTION meton_ledger.http_checkout_confirm(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
CREATE FUNCTION meton_ledger.http_checkout_order(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_ledger.apply_checkout_http('order',$1,$2,$3,$4,$5,$6) $$;
REVOKE ALL ON FUNCTION meton_ledger.http_checkout_order(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
