-- 仅传递原注销范围；两种用途继续由原生管理员及原账号固定权限复验。
CREATE FUNCTION meton_ledger.checkout_cash_closure_scope(action text,q jsonb,orig jsonb,closure uuid) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner jsonb:=orig||jsonb_build_object('source_system',meton_ledger.notification_system_id()); value jsonb;
BEGIN
    IF q-ARRAY['version','origin','intent','registration','sourceSystem','identity','inspection','inventoryHash','confirmationHash','validUntil']<>'{}'::jsonb OR
        q->>'sourceSystem' IS DISTINCT FROM owner->>'source_system' OR
        (q->>'registration'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND
         q->>'inspection'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND
         q->>'inventoryHash'~'^[0-9a-f]{64}$' AND q->>'confirmationHash'~'^[0-9a-f]{64}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'original closure scope input required' USING ERRCODE='22023'; END IF;
    IF action='closure_bind' THEN
        value:=meton_ledger.bind_cash_closure_scope(owner,closure,(q->>'inspection')::uuid,(q->>'registration')::uuid,
            q->'identity',q->>'inventoryHash',q->>'confirmationHash');
    ELSIF action='closure_scope' THEN
        value:=meton_ledger.read_cash_closure_scope(owner,closure,(q->>'registration')::uuid);
        IF value IS NOT NULL AND (value->>'inspection',value->'identity',value->>'inventoryHash',value->>'confirmationHash') IS DISTINCT FROM
            (q->>'inspection',q->'identity',q->>'inventoryHash',q->>'confirmationHash') THEN
            RAISE EXCEPTION 'original closure confirmation differs' USING ERRCODE='23505'; END IF;
    ELSE RAISE EXCEPTION 'invalid closure scope purpose' USING ERRCODE='42501'; END IF;
    RETURN value::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.checkout_cash_closure_scope(text,jsonb,jsonb,uuid) FROM PUBLIC;

ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel','lifecycle',
        'refund_quote','refund_quote_status','refund_confirm','refund_status','refund_cancel','dispute_submit','dispute_status',
        'closure_open','closure_page','closure_bind','closure_scope'));
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    reads constant text:='(''status'',''order'',''refund_quote_status'',''refund_status'',''dispute_status'',''closure_page'')';action text;
BEGIN
    IF cardinality(string_to_array(body,reads))<>3 OR cardinality(string_to_array(body,'NOT IN (''closure_open'',''closure_page'''))<>2 OR
        cardinality(string_to_array(body,'WHEN ''lifecycle'' THEN'))<>2 THEN
        RAISE EXCEPTION 'original closure scope HTTP branches changed'; END IF;
    body:=replace(body,'NOT IN (''closure_open'',''closure_page''','NOT IN (''closure_bind'',''closure_scope'',''closure_open'',''closure_page''');
    body:=replace(body,reads,'(''status'',''order'',''refund_quote_status'',''refund_status'',''dispute_status'',''closure_page'',''closure_scope'')');
    body:=replace(body,'WHEN ''lifecycle'' THEN',$branch$WHEN 'closure_bind','closure_scope' THEN
        result:=meton_ledger.checkout_cash_closure_scope(p_action,q,orig,sid);
        WHEN 'lifecycle' THEN$branch$);
    EXECUTE body;
    FOREACH action IN ARRAY ARRAY['closure_bind','closure_scope'] LOOP
        EXECUTE format('CREATE FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS %L',
            'http_checkout_'||action,format('SELECT meton_ledger.apply_checkout_http(%L,$1,$2,$3,$4,$5,$6)',action));
        EXECUTE format('REVOKE ALL ON FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC','http_checkout_'||action);
    END LOOP;
END $extend$;
