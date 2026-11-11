-- 替代退回复用原退款和 R，不创建第二张退款或第二笔本金。独立决策未明确撤回之前，旧取消证明不能释放 R。
CREATE TABLE meton_ledger.refund_alternative_intents(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_aftercare_cases,
    proposal jsonb NOT NULL, digest bytea NOT NULL CHECK(octet_length(digest)=32),
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE TABLE meton_ledger.refund_alternative_decisions(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_alternative_intents,
    choice text NOT NULL CHECK(choice IN ('reserved','abandoned')), ticket uuid NOT NULL UNIQUE,
    digest bytea NOT NULL CHECK(octet_length(digest)=32)
);
DO $protect$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['refund_alternative_intents','refund_alternative_decisions'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',n);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',n);
    END LOOP;
END $protect$;

/** 与原取消共用账号、原付款、原批次和退款行锁；核验与批准不能替代对真实 R 的重新检查。 */
CREATE FUNCTION meton_ledger.original_alternative_source_share(context jsonb,ref uuid) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_ledger.cash_refunds;q meton_ledger.cash_refund_quotes;reserved numeric;credit uuid;
BEGIN
    IF context IS NULL OR context->>'phase' NOT IN ('held','possibly_sent','unknown') THEN RETURN false; END IF;
    SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE refund_id=ref;
    SELECT h.* INTO STRICT q FROM meton_ledger.cash_refund_decisions d JOIN meton_ledger.cash_refund_quotes h USING(quote_id) WHERE d.refund_id=ref;
    IF EXISTS(SELECT FROM meton_ledger.refund_cash_confirmations WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_ledger.refund_payment_disputes WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries WHERE refund_id=ref) THEN RETURN false; END IF;
    IF r.basis='purchased_source' THEN
        credit:=(q.snapshot->>'creditEvent')::uuid;
        SELECT sum(x.requested_units) INTO reserved FROM meton_ledger.cash_refunds x JOIN meton_ledger.cash_refund_decisions d USING(refund_id)
            JOIN meton_ledger.cash_refund_quotes h USING(quote_id) WHERE d.source_marker=(context->>'marker')::uuid
            AND (h.snapshot->>'creditEvent')::uuid=credit AND x.phase NOT IN ('released','settled') AND x.basis='purchased_source';
        RETURN EXISTS(SELECT FROM meton_ledger.lots WHERE credit_event=credit AND refundable AND denomination='CNY'
            AND refund_held=reserved AND refund_held>=r.requested_units AND remaining>=held+refund_held);
    END IF;
    IF r.part_id IS NOT NULL THEN
        RETURN EXISTS(SELECT FROM meton_ledger.cash_parts p JOIN meton_ledger.cash_payment_dispositions d USING(payment_id)
            WHERE p.part_id=r.part_id AND p.source_marker=(context->>'marker')::uuid AND p.basis='unposted_cash' AND d.state='restricted');
    END IF;
    -- 历史现金缺少能核对的付款占用时保持恢复核对，不从总余额反推可退份额。
    RETURN false;
END $$;

/** 来源先持久保存同一批准，再签短期准备证明。应答丢失的重试只能读取同一份额和收款归属。 */
CREATE FUNCTION meton_ledger.prepare_original_alternative(route jsonb,ref uuid,approval jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    f jsonb:=approval->'facts';p jsonb:=f->'proposal';s jsonb;out jsonb;kept meton_ledger.refund_alternative_intents;
BEGIN
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF context IS NULL THEN RETURN jsonb_build_object('state','original_unavailable'); END IF;
    IF approval->>'state' IS DISTINCT FROM 'approval_ready' OR f->'scope' IS DISTINCT FROM s OR p->'envelope' IS DISTINCT FROM context->'envelope' OR
        ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds' AND
        p#>>'{payment,rail}'='meton-isolated-transfer' AND p#>>'{payment,environment}'='isolated' AND p#>>'{payment,currency}'='CNY'
        AND p#>>'{payment,fen}'=context->>'fen' AND p->>'refund'=ref::text AND p->>'intent'=context->>'intent') IS NOT TRUE OR
        approval->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.approval.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'original alternative approval differs' USING ERRCODE='42501'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.refund_alternative_decisions WHERE refund=ref AND choice='abandoned') THEN RETURN jsonb_build_object('state','abandoned'); END IF;
    IF NOT meton_ledger.original_alternative_source_share(context,ref) THEN RETURN jsonb_build_object('state','source_restricted'); END IF;
    INSERT INTO meton_ledger.refund_alternative_intents(refund,proposal,digest) VALUES(ref,p,sha256(convert_to(p::text,'UTF8'))) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT kept FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    IF kept.proposal IS DISTINCT FROM p THEN RAISE EXCEPTION 'original alternative intent already bound' USING ERRCODE='42501'; END IF;
    IF kept.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    out:=jsonb_build_object('format',1,'scope',s,'proposal',p,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','source_ready','facts',out,'mac',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.alternative.reserve.v1',out)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 撤回也是原号操作；只请求独立库作决定，尚未得到确定撤回前不解除原占用保护。 */
CREATE FUNCTION meton_ledger.prepare_original_alternative_stop(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);p meton_ledger.refund_alternative_intents;f jsonb;
BEGIN
    SELECT * INTO p FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    IF context IS NULL OR p.refund IS NULL THEN RETURN jsonb_build_object('state','original_unavailable'); END IF;
    IF p.proposal->'envelope' IS DISTINCT FROM context->'envelope' THEN RETURN jsonb_build_object('state','recovery_review'); END IF;
    f:=jsonb_build_object('format',1,'scope',jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system),'proposal',p.proposal,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','source_ready','facts',f,'mac',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.alternative.abandon.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 只接回已经独立提交的唯一选择。批准不是现金成功，撤回也只解除替代流程的保护，不直接释放 R。 */
CREATE FUNCTION meton_ledger.apply_original_alternative_decision(route jsonb,ref uuid,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    p meton_ledger.refund_alternative_intents;d meton_ledger.refund_alternative_decisions;f jsonb:=proof->'facts';s jsonb;
BEGIN
    SELECT * INTO p FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    IF context IS NULL OR p.refund IS NULL THEN RETURN 'recovery_review'; END IF;
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF proof->>'state' IS DISTINCT FROM 'decision_proved' OR f->'scope' IS DISTINCT FROM s OR f->'proposal' IS DISTINCT FROM p.proposal OR
        p.proposal->'envelope' IS DISTINCT FROM context->'envelope' OR ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds'
        AND f->>'choice' IN ('reserved','abandoned') AND (f->>'ticket')::uuid IS NOT NULL) IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.decided.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified alternative decision' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_ledger.refund_alternative_decisions VALUES(ref,f->>'choice',(f->>'ticket')::uuid,p.digest) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    IF (d.choice,d.ticket,d.digest) IS DISTINCT FROM (f->>'choice',(f->>'ticket')::uuid,p.digest) THEN RETURN 'recovery_review'; END IF;
    RETURN d.choice;
END $$;

DO $guard$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb)'::regprocedure);
    point text:='proof_hash:=sha256(convert_to(jsonb_build_array(g.target,choice,f->>''ticket'')::text,''UTF8''));';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original refund release check changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_ledger.refund_alternative_intents i WHERE i.refund=ref AND NOT EXISTS(
        SELECT FROM meton_ledger.refund_alternative_decisions x WHERE x.refund=ref AND x.choice=''abandoned'')) THEN RETURN ''review''; END IF;
    '||point);
END $guard$;

CREATE OR REPLACE FUNCTION meton_ledger.refund_aftercare_view(ref uuid,context jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE out jsonb:=meton_ledger.refund_aftercare_admission_view(ref,context);f jsonb;i meton_ledger.refund_alternative_intents;d meton_ledger.refund_alternative_decisions;
BEGIN
    IF context IS NULL THEN RETURN out; END IF;
    SELECT facts INTO f FROM meton_ledger.refund_aftercare_verifications WHERE refund=ref AND epoch=(context->>'epoch')::bigint ORDER BY revision DESC LIMIT 1;
    out:=out||jsonb_build_object('payerState',coalesce(f#>>'{verification,payerState}','unverified'),'channelState',coalesce(f#>>'{verification,channelState}','unknown'),
        'payerVerified',coalesce(f#>>'{verification,payerState}'='verified',false),'verificationRevision',f->'revision');
    SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    RETURN out||jsonb_build_object('alternativePending',i.refund IS NOT NULL AND d.refund IS NULL,
        'alternativeAuthorized',coalesce(d.choice='reserved',false),'alternativeAbandoned',coalesce(d.choice='abandoned',false),
        'alternativeOrder',i.proposal#>'{payment,order}');
END $$;
REVOKE ALL ON FUNCTION meton_ledger.original_alternative_source_share(jsonb,uuid),meton_ledger.prepare_original_alternative(jsonb,uuid,jsonb),
    meton_ledger.prepare_original_alternative_stop(jsonb,uuid),meton_ledger.apply_original_alternative_decision(jsonb,uuid,jsonb) FROM PUBLIC;
