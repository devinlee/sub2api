-- 运营选批只读原费用、原分摊及原裁决。返回数量不授予返还权限。
CREATE FUNCTION meton_ledger.read_operations_correction_basis(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_item uuid,p_basis uuid,p_limit integer,p_cursor jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    report jsonb;
    fee meton_ledger.latest_text_fees%ROWTYPE;
    ruling meton_ledger.text_correction_decisions%ROWTYPE;
    applied boolean;
    snapshot jsonb;
    after_credit uuid;
    page jsonb;
    last_credit uuid;
    has_more boolean;
BEGIN
    IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'invalid correction page size' USING ERRCODE='22023';
    END IF;
    report:=meton_ledger.find_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis);
    IF report IS NULL THEN RETURN NULL; END IF;
    SELECT * INTO fee FROM meton_ledger.latest_text_fees
        WHERE (request_id,item_id,event_id)=(p_request,p_item,p_basis);
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO ruling FROM meton_ledger.text_correction_decisions
        WHERE request_id=p_request AND item_id=p_item ORDER BY version DESC LIMIT 1;
    -- 已返以资金流水为据，只有批准或恢复材料缺失都不能报作已经返还。
    IF EXISTS(SELECT FROM meton_ledger.text_correction_decisions d JOIN meton_ledger.text_corrections x USING(decision)
              WHERE d.request_id=p_request AND d.item_id=p_item AND NOT meton_ledger.correction_has_journal(d.decision,x.journal)) THEN
        RAISE EXCEPTION 'inconsistent original correction receipt' USING ERRCODE='23514';
    END IF;
    applied:=EXISTS(SELECT FROM meton_ledger.text_corrections x WHERE x.decision=ruling.decision);
    snapshot:=jsonb_build_object('origin',report->'origin','item',p_item,'basis',p_basis,'epoch',p_epoch,
        'decision',ruling.decision,'ruling_version',coalesce(ruling.version,0),'applied',applied);
    IF p_cursor IS NOT NULL THEN
        IF jsonb_typeof(p_cursor) IS DISTINCT FROM 'object' OR p_cursor-'snapshot'-'after'<>'{}'::jsonb
            OR p_cursor->'snapshot' IS DISTINCT FROM snapshot OR jsonb_typeof(p_cursor->'after') IS DISTINCT FROM 'string'
            OR p_cursor->>'after' !~ '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' THEN
            RAISE EXCEPTION 'invalid or stale correction cursor' USING ERRCODE='22023';
        END IF;
        after_credit:=(p_cursor->>'after')::uuid;
        IF NOT EXISTS(SELECT FROM meton_ledger.text_spend_splits s JOIN meton_ledger.text_fee_reports f ON f.event_id=s.report_event
            JOIN meton_ledger.events e ON e.event_id=s.credit_event
            WHERE s.request_id=p_request AND f.request_id=p_request AND f.item_id=p_item AND e.source_marker=p_marker AND s.credit_event=after_credit) THEN
            RAISE EXCEPTION 'original correction cursor required' USING ERRCODE='22023';
        END IF;
    END IF;
    -- 使用一条语句的快照。先截取本页原批次，避免把整个历史放进返回对象。
    WITH credits AS MATERIALIZED (
        SELECT s.credit_event,e.kind,sum(s.charged)::numeric(20,8) AS charged
        FROM meton_ledger.text_spend_splits s JOIN meton_ledger.text_fee_reports f ON f.event_id=s.report_event
        JOIN meton_ledger.events e ON e.event_id=s.credit_event
        WHERE s.request_id=p_request AND f.request_id=p_request AND f.item_id=p_item AND e.source_marker=p_marker
            AND (after_credit IS NULL OR s.credit_event>after_credit)
        GROUP BY s.credit_event,e.kind ORDER BY s.credit_event LIMIT p_limit+1
    ), current_page AS (
        SELECT * FROM credits ORDER BY credit_event LIMIT p_limit
    ), quantities AS (
        SELECT c.credit_event,
            coalesce(sum((line->>'amount')::numeric) FILTER(WHERE x.decision IS NOT NULL),0)::numeric(20,8) AS returned,
            coalesce(sum((line->>'amount')::numeric) FILTER(WHERE d.decision=ruling.decision AND x.decision IS NULL),0)::numeric(20,8) AS pending
        FROM meton_ledger.text_correction_decisions d LEFT JOIN meton_ledger.text_corrections x USING(decision)
        CROSS JOIN LATERAL jsonb_array_elements(d.sources) line JOIN current_page c ON c.credit_event=(line->>'credit_event')::uuid
        WHERE d.request_id=p_request AND d.item_id=p_item GROUP BY c.credit_event
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('credit_event',c.credit_event,'kind',c.kind,'net_charged',c.charged::text,
            'returned',coalesce(q.returned::text,'0.00000000'),'pending_approved',coalesce(q.pending::text,'0.00000000'))
            ORDER BY c.credit_event),'[]'::jsonb),
        (SELECT credit_event FROM current_page ORDER BY credit_event DESC LIMIT 1),
        (SELECT count(*)>p_limit FROM credits)
    INTO page,last_credit,has_more FROM current_page c LEFT JOIN quantities q USING(credit_event);
    RETURN jsonb_build_object('format_version',1,'report',report,'funded',fee.funded::text,'uncovered',fee.uncovered::text,
        'snapshot',snapshot,'final',ruling.final,'rows',page,
        'next',CASE WHEN has_more THEN jsonb_build_object('snapshot',snapshot,'after',last_credit) END);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_operations_correction_basis(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,integer,jsonb) FROM PUBLIC;
