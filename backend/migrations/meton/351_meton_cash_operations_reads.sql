-- 运营查询只读原事项；独立身份不继承会员账单、现金发送或来源写入权限。
CREATE TABLE meton_ledger.cash_operations_readers(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),reader name NOT NULL UNIQUE,
    PRIMARY KEY(deployment,source,epoch,reader)
);
CREATE TRIGGER immutable_cash_operations_reader BEFORE UPDATE OR DELETE ON meton_ledger.cash_operations_readers
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_operations_readers ENABLE ALWAYS TRIGGER immutable_cash_operations_reader;
REVOKE ALL ON meton_ledger.cash_operations_readers FROM PUBLIC;

/** 一页重新核对原账号和当前代次；游标只用于有界扫描，不声称多页原子一致或赋予处置权。 */
CREATE FUNCTION meton_ledger.read_cash_operations(o jsonb,p_after text,p_size integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations; inventory jsonb; candidates jsonb; page jsonb; more boolean; next_key text;
BEGIN
    IF current_setting('transaction_read_only')<>'on' OR current_setting('transaction_isolation')<>'read committed' THEN
        RAISE EXCEPTION 'cash operations require current read-only transaction' USING ERRCODE='25006'; END IF;
    IF (jsonb_typeof(o)='object' AND o ?& ARRAY['environment','source','epoch','user','account','creation','dispatch','remote_user','source_marker','source_system']
        AND o-ARRAY['environment','source','epoch','user','account','creation','dispatch','remote_user','source_marker','source_system']='{}'::jsonb) IS NOT TRUE
        OR p_size IS NULL OR p_size NOT BETWEEN 1 AND 100 OR p_after IS NOT NULL AND p_after!~'^[a-z_]+/[A-Za-z0-9_./:-]{1,200}$' THEN
        RAISE EXCEPTION 'bounded original cash operations request required' USING ERRCODE='22023'; END IF;
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_operations_readers r WHERE
        (r.deployment,r.source,r.epoch,r.reader)=(o->>'environment',o->>'source',(o->>'epoch')::bigint,session_user)) THEN
        RAISE EXCEPTION 'separate current cash operations reader required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_refund_owner(o);
    m:=meton_ledger.statement_owner(o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'user')::uuid,
        (o->>'account')::uuid,(o->>'creation')::uuid,(o->>'dispatch')::uuid,(o->>'remote_user')::bigint,(o->>'source_marker')::uuid);
    -- 原完整清单已经处理历史截点、现金与来源分态；不能另以余额或旧投影猜测一笔资金是否已结清。
    inventory:=meton_ledger.cash_closure_inventory(o);
    SELECT coalesce(jsonb_agg(v ORDER BY v->>'key' COLLATE "C"),'[]'::jsonb) INTO candidates FROM (
        SELECT jsonb_build_object('key',(item->>'kind')||'/'||(item->>'ref'),'item',item) v
        FROM jsonb_array_elements(inventory->'items') item
        WHERE item->>'kind' IN ('order','payment','cash_basis','legacy_order','legacy_basis','legacy_activity','legacy_refund_audit',
            'unmapped_order','refund','cash_review','dispute')
          AND (p_after IS NULL OR ((item->>'kind')||'/'||(item->>'ref')) COLLATE "C">p_after COLLATE "C")
        ORDER BY ((item->>'kind')||'/'||(item->>'ref')) COLLATE "C" LIMIT p_size+1
    ) rows;
    more:=jsonb_array_length(candidates)>p_size;
    SELECT coalesce(jsonb_agg(jsonb_build_object('key',entry->>'key','openedAt',CASE entry#>>'{item,kind}'
        WHEN 'payment' THEN (SELECT paid_at FROM meton_ledger.cash_payments WHERE payment_id=(entry#>>'{item,ref}')::uuid AND source_marker=m.source_marker)
        WHEN 'cash_basis' THEN (SELECT p.paid_at FROM meton_ledger.cash_parts b JOIN meton_ledger.cash_payments p USING(payment_id)
            WHERE b.part_id=(entry#>>'{item,ref}')::uuid AND b.source_marker=m.source_marker)
        WHEN 'refund' THEN (SELECT recorded_at FROM meton_ledger.cash_refund_decisions WHERE refund_id=(entry#>>'{item,ref}')::uuid AND source_marker=m.source_marker)
        WHEN 'dispute' THEN (SELECT min(recorded_at) FROM meton_ledger.cash_dispute_statuses WHERE dispute=(entry#>>'{item,ref}')::uuid AND marker=m.source_marker)
        ELSE NULL END,
        'basisDigest',encode(sha256(convert_to(jsonb_build_array('meton.cash.operations.v1',o,entry->'item')::text,'UTF8')),'hex'),
        'original',meton_ledger.cash_statement_item(o,entry->'item')) ORDER BY ordinal),'[]'::jsonb)
        INTO page FROM jsonb_array_elements(candidates) WITH ORDINALITY t(entry,ordinal) WHERE ordinal<=p_size;
    next_key:=CASE WHEN jsonb_array_length(page)>0 THEN page->-1->>'key' ELSE p_after END;
    -- 公共字段清单同时用于内部运营；不把原付款报文、审核材料、签章或秘密混入普通查询结果。
    IF octet_length(page::text)>196608 THEN RAISE EXCEPTION 'cash operations page exceeds budget' USING ERRCODE='54000'; END IF;
    RETURN jsonb_build_object('format',1,'state','observed','origin',o,'observedAt',statement_timestamp(),
        'scope','current_original_page','after',p_after,'size',p_size,'next',next_key,'more',more,'items',page,
        'financialAuthority',false,'executionAuthorized',false);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_cash_operations(jsonb,text,integer) FROM PUBLIC;
