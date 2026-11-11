-- 替代停止复用原 R 的释放，不产生补款、赠送或第二份余额。原路与替代路径共用这一段原账本操作。
CREATE FUNCTION meton_ledger.release_original_refund_hold(p_marker uuid,r meton_ledger.cash_refunds,q meton_ledger.cash_refund_quotes,proof_hash bytea) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE credit uuid;total_held numeric;
BEGIN
    IF r.basis='purchased_source' THEN
        credit:=(q.snapshot->>'creditEvent')::uuid;
        SELECT sum(x.requested_units) INTO total_held FROM meton_ledger.cash_refunds x JOIN meton_ledger.cash_refund_decisions d USING(refund_id)
            JOIN meton_ledger.cash_refund_quotes h USING(quote_id) WHERE d.source_marker=p_marker AND (h.snapshot->>'creditEvent')::uuid=credit
            AND x.phase NOT IN ('released','settled') AND x.basis='purchased_source';
        UPDATE meton_ledger.lots SET refund_held=refund_held-r.requested_units WHERE credit_event=credit AND refundable AND
            refund_held=total_held AND refund_held>=r.requested_units;
        IF NOT FOUND THEN RAISE EXCEPTION 'original purchase hold needs recovery' USING ERRCODE='55000'; END IF;
    ELSIF r.part_id IS NOT NULL THEN
        UPDATE meton_ledger.cash_payment_dispositions d SET version=version+1 FROM meton_ledger.cash_parts p
            WHERE p.part_id=r.part_id AND p.source_marker=p_marker AND d.payment_id=p.payment_id AND d.state='restricted';
        IF NOT FOUND THEN RAISE EXCEPTION 'original unposted cash needs recovery' USING ERRCODE='55000'; END IF;
    END IF;
    UPDATE meton_ledger.cash_refunds SET phase='released',disposition_version=disposition_version+1 WHERE refund_id=r.refund_id;
    INSERT INTO meton_ledger.cash_refund_recoveries VALUES(r.refund_id,r.disposition_version+1,'released',0,0,proof_hash);
    RETURN 'released';
END $$;

-- 仅提取原校验之后的资金释放段，原资格、签名、回放和关闭通知校验均保留。
DO $reuse$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb)'::regprocedure);
    first text:='IF r.basis=''purchased_source'' THEN';
    last text:='INSERT INTO meton_ledger.cash_refund_recoveries VALUES(ref,r.disposition_version+1,''released'',0,0,proof_hash);';
    begin_at integer;end_at integer;
BEGIN
    IF cardinality(string_to_array(body,first))<>2 OR cardinality(string_to_array(body,last))<>2 THEN RAISE EXCEPTION 'original hold release changed'; END IF;
    begin_at:=strpos(body,first);end_at:=strpos(body,last)+length(last);
    IF end_at<=begin_at THEN RAISE EXCEPTION 'original release order changed'; END IF;
    EXECUTE substring(body FROM 1 FOR begin_at-1)||'PERFORM meton_ledger.release_original_refund_hold(g.marker,r,q,proof_hash);'||substring(body FROM end_at);
END $reuse$;

CREATE TABLE meton_ledger.refund_alternative_closures(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_alternative_intents,
    terminal jsonb NOT NULL,evidence bytea NOT NULL CHECK(octet_length(evidence)=32)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_alternative_closures FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_alternative_closures ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_alternative_closures FROM PUBLIC;

/** 只有当前独立权威证明两路都未付、所有旧替代发送者已停止，才复用原份额释放；重复只读原结局。 */
CREATE FUNCTION meton_ledger.resolve_alternative_closed(route jsonb,ref uuid,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);i meton_ledger.refund_alternative_intents;
    d meton_ledger.refund_alternative_decisions;r meton_ledger.cash_refunds;q meton_ledger.cash_refund_quotes;
    f jsonb:=proof->'facts';closed_value jsonb:=f->'terminal';scope jsonb;hash bytea;payment uuid;marker uuid;
BEGIN
    IF context IS NULL THEN RETURN 'original_unavailable'; END IF;
    SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF proof->>'state' IS DISTINCT FROM 'alternative_closed' OR f->>'state' IS DISTINCT FROM 'alternative_closed' OR f->'scope' IS DISTINCT FROM scope OR
        d.choice IS DISTINCT FROM 'reserved' OR f->'proposal' IS DISTINCT FROM i.proposal OR i.proposal->'envelope' IS DISTINCT FROM context->'envelope' OR
        closed_value->>'ticket' IS DISTINCT FROM d.ticket::text OR closed_value->>'originalChannel' IS DISTINCT FROM 'closed_unpaid' OR
        (closed_value->>'reason' IN ('unsent','channel_closed') AND closed_value->>'stopReason' IN ('member_cancel','failed') AND
            (f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        f->>'terminalHash' IS DISTINCT FROM encode(sha256(convert_to(closed_value::text,'UTF8')),'hex') OR
        proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.closed.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified alternative closure' USING ERRCODE='42501'; END IF;
    hash:=sha256(convert_to(jsonb_build_array('meton.refund.alternative.released.v1',i.proposal,closed_value)::text,'UTF8'));
    marker:=(context->>'marker')::uuid;
    SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE refund_id=ref;
    SELECT h.* INTO STRICT q FROM meton_ledger.cash_refund_decisions x JOIN meton_ledger.cash_refund_quotes h USING(quote_id) WHERE x.refund_id=ref;
    IF r.part_id IS NOT NULL THEN SELECT payment_id INTO STRICT payment FROM meton_ledger.cash_parts WHERE part_id=r.part_id; END IF;
    IF EXISTS(SELECT FROM meton_ledger.refund_cash_confirmations WHERE refund=ref) OR EXISTS(SELECT FROM meton_ledger.refund_alternative_cash WHERE refund=ref) THEN
        RETURN meton_ledger.record_refund_dispute(ref,hash,'alternative_closed_after_cash',1); END IF;
    IF meton_ledger.refund_payment_disputed(marker,r.native_order,payment,r.legacy_cutoff) THEN RETURN 'review'; END IF;
    IF r.phase='released' THEN
        IF EXISTS(SELECT FROM meton_ledger.refund_alternative_closures c JOIN meton_ledger.cash_refund_recoveries x ON c.refund=x.refund_id
            WHERE c.refund=ref AND c.terminal=closed_value AND c.evidence=hash AND x.phase='released' AND x.terminal_version=r.disposition_version AND x.evidence=hash) THEN RETURN 'released'; END IF;
        RETURN 'recovery_review';
    END IF;
    IF NOT meton_ledger.original_alternative_source_share(context,ref) THEN RETURN 'recovery_review'; END IF;
    PERFORM meton_ledger.release_original_refund_hold(marker,r,q,hash);
    INSERT INTO meton_ledger.refund_alternative_closures VALUES(ref,closed_value,hash);
    RETURN 'released';
END $$;

-- 原关闭通知只在同一退款已明确释放、字段逐项一致且没有争议时视作已处理；迟到 SUCCESS 仍然受限。
DO $observations$
DECLARE body text:=pg_get_functiondef('meton_ledger.refund_observation_resolved(meton_ledger.cash_refund_observations)'::regprocedure);
    point text:='SELECT meton_ledger.refund_observation_settled(s) OR EXISTS(';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'closed observation projection changed'; END IF;
    EXECUTE replace(body,point,$new$SELECT EXISTS(SELECT FROM meton_ledger.refund_alternative_closures c
        JOIN meton_ledger.cash_refunds r ON r.refund_id=c.refund JOIN meton_ledger.refund_alternative_intents i ON i.refund=c.refund
        JOIN meton_ledger.cash_parts p ON p.part_id=r.part_id
        WHERE r.phase='released' AND r.native_order=s.native_order AND s.facts->>'state'='CLOSED' AND
            (s.source_marker::text,s.channel,s.cash_environment,s.merchant_id,s.transaction_id)=
                (i.proposal#>>'{envelope,target,marker}',i.proposal#>>'{envelope,scope,channel}',i.proposal#>>'{envelope,scope,cashEnvironment}',i.proposal#>>'{envelope,scope,merchant}',i.proposal#>>'{envelope,cash,transaction}') AND
            (s.facts->>'order',s.facts->>'transaction',s.facts->>'refundOrder',s.facts->>'refundID',s.facts->>'total',s.facts->>'payerTotal',s.facts->>'refundFen',s.facts->>'payerRefund')=
                (c.terminal#>>'{originalClosed,order}',c.terminal#>>'{originalClosed,transaction}',c.terminal#>>'{originalClosed,refundOrder}',c.terminal#>>'{originalClosed,refundID}',
                c.terminal#>>'{originalClosed,total}',c.terminal#>>'{originalClosed,payerTotal}',c.terminal#>>'{originalClosed,refundFen}',c.terminal#>>'{originalClosed,payerRefund}') AND
            NOT meton_ledger.refund_payment_disputed(s.source_marker,r.native_order,p.payment_id,r.legacy_cutoff)) OR meton_ledger.refund_observation_settled(s) OR EXISTS($new$);
    body:=pg_get_functiondef('meton_ledger.refund_aftercare_view(uuid,jsonb)'::regprocedure);
    point:='''alternativeAuthorized'',coalesce(d.choice=''reserved'',false)';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative status changed'; END IF;
    EXECUTE replace(body,point,point||' AND NOT EXISTS(SELECT FROM meton_ledger.refund_alternative_closures WHERE refund=ref),
        ''alternativeStopped'',EXISTS(SELECT FROM meton_ledger.refund_alternative_closures WHERE refund=ref)');
END $observations$;
REVOKE ALL ON FUNCTION meton_ledger.release_original_refund_hold(uuid,meton_ledger.cash_refunds,meton_ledger.cash_refund_quotes,bytea),
    meton_ledger.resolve_alternative_closed(jsonb,uuid,jsonb) FROM PUBLIC;
