-- 只读原操作用于补查未知受理；不创建控制记录，不把缺失解释成已经停止。
CREATE FUNCTION meton_ledger.read_cash_closure_refund(o jsonb,p_closure uuid,p_registration uuid,p_scope text,p_operation uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'read');
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration
        AND receipt->>'scopeHash'=p_scope) THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    IF p_operation IS NULL OR p_operation='00000000-0000-0000-0000-000000000000' THEN
        RAISE EXCEPTION 'original operation required' USING ERRCODE='22023'; END IF;
    RETURN (SELECT jsonb_build_object('sequence',a.sequence,'operation',a.operation,'receipt',a.receipt,
        'refundPhase',r.phase,'refundVersion',r.disposition_version)
        FROM meton_ledger.cash_closure_refund_attempts a LEFT JOIN meton_ledger.cash_refunds r ON r.refund_id=a.refund_id
        WHERE a.closure_id=p_closure AND a.operation=p_operation);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_cash_closure_refund(jsonb,uuid,uuid,text,uuid) FROM PUBLIC;

/** HTTP 复用已验原受理／停止事务；Identity 决定只能经独立服务用途进入，不能使用会员会话冒充。 */
CREATE FUNCTION meton_ledger.checkout_cash_closure_refunds(action text,q jsonb,orig jsonb,closure uuid) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner jsonb:=orig||jsonb_build_object('source_system',meton_ledger.notification_system_id()); value jsonb; target jsonb:=q->'target';
BEGIN
    IF q-ARRAY['version','origin','intent','registration','sourceSystem','scopeHash','decision','operation','target','after','limit','validUntil']<>'{}'::jsonb OR
        q->>'sourceSystem' IS DISTINCT FROM owner->>'source_system' OR
        (q->>'registration'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND q->>'scopeHash'~'^[0-9a-f]{64}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'original closure refund input required' USING ERRCODE='22023'; END IF;
    IF action='closure_refund_admit' THEN
        IF q ?| ARRAY['after','limit'] OR (jsonb_typeof(target)='object' AND
            target ?& ARRAY['order','basis'] AND target-ARRAY['order','part','cutoff','basis']='{}'::jsonb AND
            q->>'operation'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') IS NOT TRUE THEN
            RAISE EXCEPTION 'original refund target required' USING ERRCODE='22023'; END IF;
        value:=meton_ledger.admit_cash_closure_refund(owner,closure,(q->>'registration')::uuid,q->>'scopeHash',q->'decision',
            (q->>'operation')::uuid,(target->>'order')::bigint,(target->>'part')::uuid,(target->>'cutoff')::uuid,target->>'basis',(q->>'validUntil')::timestamptz);
    ELSIF action='closure_refund_stop' THEN
        IF q ?| ARRAY['operation','target','after','limit'] THEN RAISE EXCEPTION 'stop cannot select a refund' USING ERRCODE='22023'; END IF;
        value:=meton_ledger.stop_cash_closure_refunds(owner,closure,(q->>'registration')::uuid,q->>'scopeHash',q->'decision',(q->>'validUntil')::timestamptz);
    ELSIF action='closure_refunds' THEN
        IF q ?| ARRAY['decision','target'] THEN RAISE EXCEPTION 'query cannot carry an execution decision' USING ERRCODE='22023'; END IF;
        IF q ? 'operation' THEN
            IF q ?| ARRAY['after','limit'] THEN RAISE EXCEPTION 'original query and page are separate' USING ERRCODE='22023'; END IF;
            value:=meton_ledger.read_cash_closure_refund(owner,closure,(q->>'registration')::uuid,q->>'scopeHash',(q->>'operation')::uuid);
        ELSE
            value:=meton_ledger.read_cash_closure_refunds(owner,closure,(q->>'registration')::uuid,q->>'scopeHash',(q->>'after')::bigint,(q->>'limit')::int);
        END IF;
    ELSE RAISE EXCEPTION 'invalid closure refund purpose' USING ERRCODE='42501'; END IF;
    RETURN value::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.checkout_cash_closure_refunds(text,jsonb,jsonb,uuid) FROM PUBLIC;
ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel','lifecycle',
        'refund_quote','refund_quote_status','refund_confirm','refund_status','refund_cancel','dispute_submit','dispute_status',
        'closure_open','closure_page','closure_bind','closure_scope','closure_refund_admit','closure_refund_stop','closure_refunds'));
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    reads constant text:='(''status'',''order'',''refund_quote_status'',''refund_status'',''dispute_status'',''closure_page'',''closure_scope'')';action text;
BEGIN
    IF cardinality(string_to_array(body,reads))<>3 OR cardinality(string_to_array(body,'NOT IN (''closure_bind'',''closure_scope'''))<>2 OR
        cardinality(string_to_array(body,'WHEN ''lifecycle'' THEN'))<>2 THEN RAISE EXCEPTION 'original closure refund HTTP branches changed'; END IF;
    body:=replace(body,'NOT IN (''closure_bind'',''closure_scope''','NOT IN (''closure_refund_admit'',''closure_refund_stop'',''closure_refunds'',''closure_bind'',''closure_scope''');
    body:=replace(body,reads,'(''status'',''order'',''refund_quote_status'',''refund_status'',''dispute_status'',''closure_page'',''closure_scope'',''closure_refunds'')');
    body:=replace(body,'WHEN ''lifecycle'' THEN',$branch$WHEN 'closure_refund_admit','closure_refund_stop','closure_refunds' THEN
        result:=meton_ledger.checkout_cash_closure_refunds(p_action,q,orig,sid);
        WHEN 'lifecycle' THEN$branch$);
    EXECUTE body;
    FOREACH action IN ARRAY ARRAY['closure_refund_admit','closure_refund_stop','closure_refunds'] LOOP
        EXECUTE format('CREATE FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS %L',
            'http_checkout_'||action,format('SELECT meton_ledger.apply_checkout_http(%L,$1,$2,$3,$4,$5,$6)',action));
        EXECUTE format('REVOKE ALL ON FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC','http_checkout_'||action);
    END LOOP;
END $extend$;
