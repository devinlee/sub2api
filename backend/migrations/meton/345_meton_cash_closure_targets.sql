-- 只枚举原确认订单的当前退款目标，不按检查时的旧余额退款，也不扩展到后来新建的订单。
CREATE FUNCTION meton_ledger.read_cash_closure_targets(o jsonb,p_closure uuid,p_registration uuid,p_scope text,after_key text,page_size int)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s meton_ledger.cash_closure_scopes; entry record; candidates jsonb; result jsonb:='[]'; control jsonb;
    basis jsonb; previous jsonb; attempt meton_ledger.cash_closure_refund_attempts; mode text; op uuid; state text;
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'read');
    SELECT * INTO s FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration AND receipt->>'scopeHash'=p_scope;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    IF page_size IS NULL OR page_size NOT BETWEEN 1 AND 100 OR after_key IS NOT NULL AND
        after_key!~'^[0-9]{20}/[ml]/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[pu]$' THEN
        RAISE EXCEPTION 'bounded original closure target cursor required' USING ERRCODE='22023'; END IF;
    control:=meton_ledger.cash_closure_refund_control_view(p_closure);
    WITH selected AS (
        SELECT DISTINCT item->>'kind' AS kind,item->>'ref' AS ref FROM meton_ledger.cash_closure_snapshots snap,
            jsonb_array_elements(snap.items) item WHERE snap.snapshot_id=s.snapshot_id AND item->>'kind' IN ('order','legacy_order')
    ), targets AS (
        SELECT p.native_order AS ord,p.part_id AS part,NULL::uuid AS cutoff,p.basis,
            lpad(p.native_order::text,20,'0')||'/m/'||p.part_id::text||'/'||CASE p.basis WHEN 'purchased_source' THEN 'p' ELSE 'u' END AS cursor
        FROM selected JOIN meton_ledger.cash_parts p ON selected.kind='order' AND selected.ref=p.native_order::text
        WHERE p.source_marker=(o->>'source_marker')::uuid
        UNION ALL
        SELECT h.native_order,NULL::uuid,h.cutoff,v.value->>'basis',
            lpad(h.native_order::text,20,'0')||'/l/'||h.cutoff::text||'/'||CASE v.value->>'basis' WHEN 'purchased_source' THEN 'p' ELSE 'u' END
        FROM selected JOIN meton_ledger.legacy_cash_handoffs h ON selected.kind='legacy_order' AND selected.ref=h.cutoff::text||'/'||h.native_order::text
            CROSS JOIN LATERAL (SELECT meton_ledger.read_legacy_cash_order(o,h.cutoff,h.native_order) AS value) v
        WHERE h.source_marker=(o->>'source_marker')::uuid AND v.value->>'basis' IN ('purchased_source','unposted_cash')
    ) SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.cursor),'[]') INTO candidates
        FROM (SELECT * FROM targets WHERE after_key IS NULL OR cursor COLLATE "C">after_key COLLATE "C" ORDER BY cursor COLLATE "C" LIMIT page_size+1) t;
    FOR entry IN SELECT * FROM jsonb_to_recordset(candidates) AS x(ord bigint,part uuid,cutoff uuid,basis text,cursor text) LIMIT page_size LOOP
        SELECT * INTO attempt FROM meton_ledger.cash_closure_refund_attempts a WHERE a.closure_id=p_closure AND
            (a.request->>'order')::bigint=entry.ord AND (a.request->>'part')::uuid IS NOT DISTINCT FROM entry.part AND
            (a.request->>'cutoff')::uuid IS NOT DISTINCT FROM entry.cutoff AND a.request->>'basis'=entry.basis ORDER BY a.sequence DESC LIMIT 1;
        previous:=CASE WHEN attempt.operation IS NOT NULL THEN meton_ledger.read_cash_closure_refund(o,p_closure,p_registration,p_scope,attempt.operation) END;
        basis:=meton_ledger.closure_refund_basis(o,entry.ord,entry.part,entry.cutoff,entry.basis);
        state:=CASE WHEN basis->'snapshot'->>'state'='ready' THEN basis->'offer'->>'state' ELSE basis->'snapshot'->>'state' END;
        op:=NULL;
        IF control->>'state'='stopped' THEN mode:='stopped';
        ELSIF previous->'receipt'->>'refund' IS NOT NULL AND previous->>'refundPhase' NOT IN ('settled','released') THEN
            mode:='pending';op:=attempt.operation;
        ELSIF state IN ('quoted','refund_pending') THEN
            mode:='ready';
            -- 未提交不改变原操作号。已提交的原回执和现金终态来自同一只读快照，才允许下一次补退。
            op:=substr(encode(sha256(convert_to(jsonb_build_array(p_closure,entry.cursor,coalesce(attempt.sequence,0))::text,'UTF8')),'hex'),1,32)::uuid;
        ELSE mode:='waiting'; END IF;
        result:=result||jsonb_build_array(jsonb_build_object('cursor',entry.cursor,'order',entry.ord,'part',entry.part,'cutoff',entry.cutoff,
            'basis',entry.basis,'state',mode,'availability',state,'operation',op,'previous',previous));
    END LOOP;
    RETURN jsonb_build_object('control',control,'after',after_key,'items',result,'hasMore',jsonb_array_length(candidates)>page_size);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_cash_closure_targets(jsonb,uuid,uuid,text,text,int) FROM PUBLIC;

-- 原只读用途增加目标模式；旧操作查询和固定停止分页的协议及权限保持。
ALTER FUNCTION meton_ledger.checkout_cash_closure_refunds(text,jsonb,jsonb,uuid) RENAME TO checkout_cash_closure_refunds_v344;
CREATE FUNCTION meton_ledger.checkout_cash_closure_refunds(action text,q jsonb,orig jsonb,closure uuid) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner jsonb:=orig||jsonb_build_object('source_system',meton_ledger.notification_system_id());
BEGIN
    IF NOT q ?| ARRAY['targets','cursor'] THEN RETURN meton_ledger.checkout_cash_closure_refunds_v344(action,q,orig,closure); END IF;
    IF action<>'closure_refunds' OR q->'targets' IS DISTINCT FROM 'true'::jsonb OR
        q-ARRAY['version','origin','intent','registration','sourceSystem','scopeHash','targets','cursor','limit','validUntil']<>'{}'::jsonb OR
        q->>'sourceSystem' IS DISTINCT FROM owner->>'source_system' OR
        (q->>'registration'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND q->>'scopeHash'~'^[0-9a-f]{64}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'read-only original closure targets required' USING ERRCODE='22023'; END IF;
    RETURN meton_ledger.read_cash_closure_targets(owner,closure,(q->>'registration')::uuid,q->>'scopeHash',q->>'cursor',(q->>'limit')::int)::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.checkout_cash_closure_refunds(text,jsonb,jsonb,uuid) FROM PUBLIC;
