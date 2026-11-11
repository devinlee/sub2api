-- 只读关联证明与现金发送、停止及结清证明使用不同用途，不能被资金写入口消费。
CREATE FUNCTION meton_inbox.read_cash_archive_link(route jsonb,p_key text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE r meton_inbox.cash_archive_readers; a meton_inbox.refund_gate_authorities;
    page jsonb; item jsonb; link jsonb; facts jsonb; ref uuid; c meton_inbox.cash_dispute_cases;
BEGIN
    r:=meton_inbox.require_cash_archive_reader(route);
    IF p_key IS NULL THEN RAISE EXCEPTION 'exact archive key required' USING ERRCODE='22023'; END IF;
    page:=meton_inbox.cash_archive_operations_page(route,NULL,1,p_key);
    item:=page#>'{items,0}';
    IF item IS NOT NULL THEN
        CASE item#>>'{value,kind}'
        WHEN 'refund' THEN
            ref:=(item#>>'{value,refund}')::uuid;
            SELECT jsonb_build_object('kind','refund','target',b.envelope->'target') INTO link
                FROM meton_inbox.refund_wire_bindings b WHERE b.refund=ref;
        WHEN 'alternative' THEN
            ref:=(item#>>'{value,refund}')::uuid;
            SELECT jsonb_build_object('kind','refund','target',d.proposal#>'{envelope,target}') INTO link
                FROM meton_inbox.refund_alternative_decisions d WHERE d.refund=ref;
        WHEN 'dispute' THEN
            ref:=(item#>>'{value,dispute}')::uuid;
            SELECT * INTO STRICT c FROM meton_inbox.cash_dispute_cases WHERE id=ref;
            link:=jsonb_build_object('kind','dispute','ref',c.id,'revision',c.revision,'cashHash',encode(c.cash_hash,'hex'),
                'owner',jsonb_build_array(c.origin#>'{owner,user}',c.origin#>'{owner,account}',c.origin#>'{owner,source_marker}',
                    c.origin#>'{target,nativeOrder}',c.origin#>'{target,payment}',c.origin#>'{target,cutoff}'));
        ELSE
            -- 未解密通知没有可靠账号绑定；投递完成、投递号或当前会员都不能补造这个关联。
            link:=NULL;
        END CASE;
    END IF;
    SELECT * INTO STRICT a FROM meton_inbox.refund_gate_authorities WHERE
        (deployment,source,epoch,key_ref,source_system)=(r.deployment,r.source,r.epoch,r.key_ref,r.source_system);
    facts:=jsonb_build_object('format',1,'purpose','cash.archive.original.read.v1','scope',route,
        'scopeKey',page->>'scopeKey','originalKey',p_key,'item',item,'link',link,'validUntil',clock_timestamp()+interval '25 seconds');
    IF octet_length(facts::text)>32768 THEN RAISE EXCEPTION 'archive link exceeds budget' USING ERRCODE='54000'; END IF;
    RETURN jsonb_build_object('facts',facts,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.cash.archive.original.read.v1',facts)::text,'UTF8'),a.seal_key),'hex'));
END $$;
REVOKE ALL ON FUNCTION meton_inbox.read_cash_archive_link(jsonb,text) FROM PUBLIC;

-- 沿原独立读取角色增加一个精确只读方法，不借用消费者、解密或退款执行角色。
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_inbox.require_cash_archive_reader(jsonb)'::regprocedure);
    point text:='''meton_inbox.read_cash_archive_operation(jsonb,text)''::regprocedure';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'archive reader boundary changed'; END IF;
    EXECUTE replace(body,point,point||',''meton_inbox.read_cash_archive_link(jsonb,text)''::regprocedure');
END $extend$;
