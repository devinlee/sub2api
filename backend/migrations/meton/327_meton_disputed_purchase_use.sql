-- 争议事实只限制对应购买来源的新分配。原模型占用、已发生消费、原来源纠正和其他充值继续沿原账处理。
CREATE INDEX cash_return_review_payment ON meton_ledger.cash_return_reviews(payment) WHERE payment IS NOT NULL;

/** 同一实付的全部购买份额共用核对状态；历史批次沿原退款快照定位，不按用户总余额猜测。 */
CREATE FUNCTION meton_ledger.cash_purchase_needs_review(credit uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.cash_parts p JOIN meton_ledger.cash_return_reviews v
        ON (v.payment,v.marker)=(p.payment_id,p.source_marker) WHERE p.credit_event=$1)
    OR EXISTS(SELECT FROM meton_ledger.cash_return_reviews v JOIN meton_ledger.cash_refund_decisions d ON d.refund_id=v.refund
        JOIN meton_ledger.cash_refund_quotes q ON q.quote_id=d.quote_id
        WHERE v.cutoff IS NOT NULL AND (q.snapshot->>'creditEvent')::uuid=$1)
$$;
REVOKE ALL ON FUNCTION meton_ledger.cash_purchase_needs_review(uuid) FROM PUBLIC;

-- 三个入口共用原账号锁。只改空闲来源的挑选，不筛掉账实总额校验，也不拒绝按已有分配处理迟到费用。
DO $selection$
DECLARE item record;body text;
    loop_anchor text:='l.remaining>l.held+l.refund_held';
BEGIN
    FOR item IN SELECT * FROM (VALUES
        ('meton_ledger.reserve_text(text,text,bigint,uuid,uuid,uuid,text,uuid,bigint,text,text,text,integer,text,integer,integer)',NULL::text),
        ('meton_ledger.extend_text_cover(meton_ledger.text_hold_receipt,text,uuid,numeric)','WHERE e.source_marker=h.source_marker;'),
        ('meton_ledger.cover_text_shortfall_core(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,timestamptz)','WHERE e.source_marker=p_marker;')
    ) AS target(signature,sum_anchor) LOOP
        body:=pg_get_functiondef(item.signature::regprocedure);
        IF cardinality(string_to_array(body,loop_anchor))<>2 OR
            (item.sum_anchor IS NOT NULL AND cardinality(string_to_array(body,item.sum_anchor))<>2) THEN
            RAISE EXCEPTION 'original available source selection changed'; END IF;
        body:=replace(body,loop_anchor,loop_anchor||' AND NOT meton_ledger.cash_purchase_needs_review(l.credit_event)');
        IF item.sum_anchor IS NOT NULL THEN
            body:=replace(body,item.sum_anchor,replace(item.sum_anchor,';',' AND NOT meton_ledger.cash_purchase_needs_review(l.credit_event);'));
        END IF;
        EXECUTE body;
    END LOOP;
END $selection$;

-- 已有 H 保留并允许原号取消，但尚未派发的任务不能凭过去的预占继续消耗已受限原款。
DO $dispatch$
DECLARE body text:=pg_get_functiondef('meton_ledger.claim_text_dispatch(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,bigint,text)'::regprocedure);
    point text:='INSERT INTO meton_ledger.text_send_decisions(request_id,state)';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original dispatch claim changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_ledger.text_all_slices a WHERE a.request_id=p_request
        AND meton_ledger.cash_purchase_needs_review(a.credit_event)) THEN RETURN false; END IF; '||point);
END $dispatch$;
