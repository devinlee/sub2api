-- 会员只能提交本人原争议材料。材料正文不在来源库持久化，受理证明不授予审核或资金写权限。
CREATE FUNCTION meton_ledger.prepare_member_dispute(action text,req jsonb,orig jsonb,person jsonb,operation uuid,deadline timestamptz)
RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner jsonb:=orig||jsonb_build_object('source_system',meton_ledger.notification_system_id());
    item jsonb:=req->'memberDispute';d meton_ledger.cash_dispute_statuses;a meton_ledger.refund_gate_authorities;
    material bytea;submission jsonb;f jsonb;
BEGIN
    PERFORM meton_ledger.require_refund_actor(owner,person,deadline);
    IF req-ARRAY['version','origin','desktop','intent','validUntil','memberDispute']<>'{}'::jsonb OR
        (item->>'id'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'member dispute context required' USING ERRCODE='22023'; END IF;
    -- 与退出和账号限制按同一原会话锁排序；跨库提交完成前一直保留锁，迟到旧请求不能另找账号。
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((orig->>'source_marker')::uuid));
    PERFORM pg_advisory_xact_lock_shared(hashtextextended(((orig->>'source_marker')::uuid)::text||':'||((person->>'session')::uuid)::text,0));
    PERFORM meton_ledger.require_refund_actor(owner,person,deadline);
    SELECT * INTO d FROM meton_ledger.cash_dispute_statuses WHERE dispute=(item->>'id')::uuid AND marker=(orig->>'source_marker')::uuid
        ORDER BY revision DESC LIMIT 1;
    IF d.dispute IS NULL THEN
        IF action='dispute_status' THEN RETURN NULL; END IF;
        RAISE EXCEPTION 'original member dispute unavailable' USING ERRCODE='42501'; END IF;
    IF d.value#>>'{owner,0}' IS DISTINCT FROM orig->>'user' OR d.value#>>'{owner,1}' IS DISTINCT FROM orig->>'account' THEN
        RAISE EXCEPTION 'original member owner differs' USING ERRCODE='42501'; END IF;
    IF action='dispute_submit' THEN
        IF item-ARRAY['id','expected','kind','material']<>'{}'::jsonb OR
            (item->>'expected'~'^[1-9][0-9]{0,17}$' AND item->>'kind' IN ('appeal','supplement')) IS NOT TRUE THEN
            RAISE EXCEPTION 'invalid member submission' USING ERRCODE='22023'; END IF;
        material:=decode(item->>'material','base64');
        IF (octet_length(material) BETWEEN 1 AND 524288) IS NOT TRUE THEN RAISE EXCEPTION 'invalid member material' USING ERRCODE='22023'; END IF;
        submission:=jsonb_build_object('format',1,'dispute',d.dispute,'operation',operation,'original',encode(d.original,'hex'),
            'authority',jsonb_build_array(orig->>'environment',orig->>'source'),'owner',d.value->'owner',
            'expected',(item->>'expected')::bigint,'kind',item->>'kind','materialHash',encode(sha256(material),'hex'));
    ELSIF action<>'dispute_status' OR item-ARRAY['id']<>'{}'::jsonb THEN
        RAISE EXCEPTION 'invalid member dispute action' USING ERRCODE='22023';
    END IF;
    SELECT * INTO a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=(orig->>'environment',orig->>'source',(orig->>'epoch')::bigint);
    IF a.key_ref IS NULL THEN RAISE EXCEPTION 'current dispute authority unavailable' USING ERRCODE='55000'; END IF;
    f:=jsonb_build_object('format',1,'action',action,'scope',jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,
        'keyRef',a.key_ref,'sourceSystem',meton_ledger.notification_system_id(),'inboxSystem',a.inbox_system),
        'dispute',d.dispute,'operation',operation,'original',encode(d.original,'hex'),'owner',d.value->'owner',
        'subject',person,'request',submission,'validUntil',deadline);
    RETURN jsonb_build_object('facts',f,'mac',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.cash.dispute.member.v1',f)::text,'UTF8'),a.seal_key),'hex'))::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.prepare_member_dispute(text,jsonb,jsonb,jsonb,uuid,timestamptz) FROM PUBLIC;

ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel','lifecycle',
        'refund_quote','refund_quote_status','refund_confirm','refund_status','refund_cancel','dispute_submit','dispute_status'));
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    actions constant text:='''refund_quote'',''refund_quote_status'',''refund_confirm'',''refund_status'',''refund_cancel''';
    reads constant text:='(''status'',''order'',''refund_quote_status'',''refund_status'')';name text;
BEGIN
    IF cardinality(string_to_array(body,actions))<>3 OR cardinality(string_to_array(body,reads))<>3 OR
        cardinality(string_to_array(body,'NOT IN (''issue'',''redeem'''))<>2 OR cardinality(string_to_array(body,'WHEN ''lifecycle'' THEN'))<>2 OR cardinality(string_to_array(body,'octet_length(p_wire)>8192'))<>2 THEN
        RAISE EXCEPTION 'original member HTTP branches changed'; END IF;
    -- 只扩展准入名单，不把申诉交给退款算法。
    body:=replace(body,'NOT IN (''issue'',''redeem''','NOT IN (''dispute_submit'',''dispute_status'',''issue'',''redeem''');
    body:=replace(body,'octet_length(p_wire)>8192','octet_length(p_wire)>(CASE WHEN p_action=''dispute_submit'' THEN 786432 ELSE 8192 END)');
    body:=replace(body,reads,'(''status'',''order'',''refund_quote_status'',''refund_status'',''dispute_status'')');
    body:=replace(body,'WHEN ''lifecycle'' THEN',$branch$WHEN 'dispute_submit','dispute_status' THEN
        result:=meton_ledger.prepare_member_dispute(p_action,q,orig,desk,sid,deadline);
        WHEN 'lifecycle' THEN$branch$);
    EXECUTE body;
    FOREACH name IN ARRAY ARRAY['dispute_submit','dispute_status'] LOOP
        EXECUTE format('CREATE FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS %L',
            'http_checkout_'||name,format('SELECT meton_ledger.apply_checkout_http(%L,$1,$2,$3,$4,$5,$6)',name));
        EXECUTE format('REVOKE ALL ON FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC','http_checkout_'||name);
    END LOOP;
END $extend$;
