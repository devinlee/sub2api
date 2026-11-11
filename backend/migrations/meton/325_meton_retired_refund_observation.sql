-- 已核实的失败只释放这笔原退款。其关闭通知不能永久挡住下一笔报价；不明、异常或迟到成功仍须限制原付款。
CREATE TABLE meton_ledger.refund_closed_returns(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.cash_refund_recoveries, ticket uuid NOT NULL,
    terminal jsonb NOT NULL, evidence bytea NOT NULL CHECK(octet_length(evidence)=32)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_closed_returns FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_closed_returns ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_closed_returns FROM PUBLIC;

CREATE FUNCTION meton_ledger.remember_closed_return(ref uuid,receipt jsonb,h bytea) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE f jsonb:=receipt->'facts'; old meton_ledger.refund_closed_returns;
BEGIN
    IF f->>'choice' IS DISTINCT FROM 'failed' THEN RETURN; END IF;
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries r JOIN meton_ledger.refund_gate_origins g ON g.refund=r.refund_id
        WHERE r.refund_id=ref AND r.phase='released' AND r.confirmed_fen=0 AND r.confirmed_units=0 AND r.evidence=h AND
            h=sha256(convert_to(jsonb_build_array(g.target,'failed',f->>'ticket',f->'terminal')::text,'UTF8'))) THEN
        RAISE EXCEPTION 'original closed return differs' USING ERRCODE='23514'; END IF;
    INSERT INTO meton_ledger.refund_closed_returns VALUES(ref,(f->>'ticket')::uuid,f->'terminal',h) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT old FROM meton_ledger.refund_closed_returns WHERE refund=ref;
    IF (old.ticket,old.terminal,old.evidence) IS DISTINCT FROM ((f->>'ticket')::uuid,f->'terminal',h) THEN
        RAISE EXCEPTION 'conflicting original closed return' USING ERRCODE='23514'; END IF;
END $$;

CREATE FUNCTION meton_ledger.refund_observation_resolved(s meton_ledger.cash_refund_observations) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.refund_observation_settled(s) OR EXISTS(
        SELECT FROM meton_ledger.refund_closed_returns f JOIN meton_ledger.cash_refunds r ON r.refund_id=f.refund
        JOIN meton_ledger.refund_gate_origins g ON g.refund=r.refund_id JOIN meton_ledger.cash_parts p ON p.part_id=r.part_id
        WHERE (r.phase,g.marker,r.native_order,r.out_refund_no)=('released',s.source_marker,s.native_order,s.facts->>'refundOrder')
            AND s.facts->>'state'='CLOSED' AND s.facts-'occurredAt'=f.terminal->'notice'
            AND (s.channel,s.cash_environment,s.merchant_id,s.transaction_id)=(f.terminal->>'channel',f.terminal->>'cashEnvironment',f.terminal->>'merchant',f.terminal#>>'{notice,transaction}')
            AND NOT meton_ledger.refund_payment_disputed(g.marker,r.native_order,p.payment_id,r.legacy_cutoff))
$$;
DO $gate$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb)'::regprocedure);
    old_complete constant text:='(ref,r.disposition_version,''released'',proof_hash)) THEN RETURN ''released''; END IF;';
    inserted constant text:='INSERT INTO meton_ledger.cash_refund_recoveries VALUES(ref,r.disposition_version+1,''released'',0,0,proof_hash);';
    old_quote constant text:='NOT meton_ledger.refund_observation_settled(signal)';
BEGIN
    IF cardinality(string_to_array(body,old_complete))<>2 OR cardinality(string_to_array(body,inserted))<>2 THEN RAISE EXCEPTION 'original failure receipt changed'; END IF;
    body:=replace(body,old_complete,'(ref,r.disposition_version,''released'',proof_hash)) THEN PERFORM meton_ledger.remember_closed_return(ref,receipt,proof_hash); RETURN ''released''; END IF;');
    EXECUTE replace(body,inserted,inserted||' PERFORM meton_ledger.remember_closed_return(ref,receipt,proof_hash);');
    body:=pg_get_functiondef('meton_ledger.original_refund_snapshot(jsonb,bigint,uuid,uuid,text)'::regprocedure);
    IF cardinality(string_to_array(body,old_quote))<>2 THEN RAISE EXCEPTION 'original refund quotation changed'; END IF;
    EXECUTE replace(body,old_quote,'NOT meton_ledger.refund_observation_resolved(signal)');
END $gate$;
REVOKE ALL ON FUNCTION meton_ledger.remember_closed_return(uuid,jsonb,bytea),meton_ledger.refund_observation_resolved(meton_ledger.cash_refund_observations) FROM PUBLIC;

-- 首版按原付款人的实付份额报价。券退回等原因造成现金实退小于本次报价时，先保留真实现金明细，原本金等待核对。
DO $payer$
DECLARE body text:=pg_get_functiondef('meton_ledger.resolve_original_refund(jsonb,uuid,jsonb)'::regprocedure);
    point constant text:='IF meton_ledger.refund_payment_disputed(g.marker,r.native_order,payment,r.legacy_cutoff)';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original refund payout comparison changed'; END IF;
    EXECUTE replace(body,point,$guard$IF (c->>'payerRefund')::bigint<>r.requested_fen OR
        (coalesce((e#>>'{cash,payerTotalUnrecorded}')::boolean,false) AND (c->>'payerTotal')::bigint<>(e#>>'{cash,total}')::bigint) THEN
        RETURN meton_ledger.record_refund_dispute(ref,confirmed,'payer_allocation_differs',1); END IF;
    $guard$||point);
END $payer$;

-- 付款参数和结清表的 payment 同名。新购买的履约先查原实付，避免列名歧义令正常付款无法入账。
DO $fulfil$
DECLARE body text:=pg_get_functiondef('meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)'::regprocedure);
    point constant text:='WHERE w.payment=payment AND w.credit IS NULL';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original fulfilment lookup changed'; END IF;
    EXECUTE replace(body,point,'WHERE w.payment=$6 AND w.credit IS NULL');
END $fulfil$;
