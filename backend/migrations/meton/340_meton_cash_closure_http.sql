-- 注销检查沿原收银台鉴权，只开放原快照采集与分页；不增加资金写入口。
CREATE FUNCTION meton_ledger.checkout_cash_closure(action text,q jsonb,orig jsonb,sid uuid) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner jsonb:=orig||jsonb_build_object('source_system',meton_ledger.notification_system_id()); value jsonb;
BEGIN
    IF (q->>'sourceSystem') IS DISTINCT FROM owner->>'source_system' OR
        q-ARRAY['version','origin','intent','registration','sourceSystem','identity','validUntil','snapshotUntil','page']<>'{}'::jsonb OR
        (q->>'registration'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'original closure inspection required' USING ERRCODE='22023'; END IF;
    IF action='closure_open' THEN
        IF q ? 'page' OR NOT(q ? 'snapshotUntil') THEN RAISE EXCEPTION 'invalid closure capture' USING ERRCODE='22023'; END IF;
        value:=meton_ledger.open_cash_closure_snapshot(owner,sid,(q->>'registration')::uuid,q->'identity',(q->>'snapshotUntil')::timestamptz);
    ELSIF action='closure_page' THEN
        IF q ? 'snapshotUntil' OR (jsonb_typeof(q->'page')='object' AND (q->'page') ?& ARRAY['after','size']
            AND (q->'page')-ARRAY['after','size']='{}'::jsonb) IS NOT TRUE THEN
            RAISE EXCEPTION 'invalid closure page' USING ERRCODE='22023'; END IF;
        value:=meton_ledger.read_cash_closure_snapshot(owner,sid,(q->>'registration')::uuid,q->'identity',
            (q#>>'{page,after}')::integer,(q#>>'{page,size}')::integer);
    ELSE RAISE EXCEPTION 'invalid closure purpose' USING ERRCODE='42501'; END IF;
    RETURN value::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.checkout_cash_closure(text,jsonb,jsonb,uuid) FROM PUBLIC;

ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel','lifecycle',
        'refund_quote','refund_quote_status','refund_confirm','refund_status','refund_cancel','dispute_submit','dispute_status','closure_open','closure_page'));
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    reads constant text:='(''status'',''order'',''refund_quote_status'',''refund_status'',''dispute_status'')';name text;
BEGIN
    IF cardinality(string_to_array(body,reads))<>3 OR cardinality(string_to_array(body,'NOT IN (''dispute_submit'',''dispute_status'',''issue'''))<>2 OR
        cardinality(string_to_array(body,'WHEN ''lifecycle'' THEN'))<>2 THEN
        RAISE EXCEPTION 'original closure HTTP branches changed'; END IF;
    body:=replace(body,'NOT IN (''dispute_submit'',''dispute_status'',''issue''','NOT IN (''closure_open'',''closure_page'',''dispute_submit'',''dispute_status'',''issue''');
    body:=replace(body,reads,'(''status'',''order'',''refund_quote_status'',''refund_status'',''dispute_status'',''closure_page'')');
    body:=replace(body,'WHEN ''lifecycle'' THEN',$branch$WHEN 'closure_open','closure_page' THEN
        result:=meton_ledger.checkout_cash_closure(p_action,q,orig,sid);
        WHEN 'lifecycle' THEN$branch$);
    EXECUTE body;
    FOREACH name IN ARRAY ARRAY['closure_open','closure_page'] LOOP
        EXECUTE format('CREATE FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS %L',
            'http_checkout_'||name,format('SELECT meton_ledger.apply_checkout_http(%L,$1,$2,$3,$4,$5,$6)',name));
        EXECUTE format('REVOKE ALL ON FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC','http_checkout_'||name);
    END LOOP;
END $extend$;
