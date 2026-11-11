-- 替代渠道保留自己的付款身份；原来源结清算法仍只处理原 R 和原退款份额。
CREATE TABLE meton_ledger.refund_alternative_cash(
    refund uuid NOT NULL REFERENCES meton_ledger.refund_alternative_intents,
    digest bytea NOT NULL CHECK(octet_length(digest)=32),cash jsonb NOT NULL,
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),PRIMARY KEY(refund,digest)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_alternative_cash
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_alternative_cash ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_alternative_cash FROM PUBLIC;

/** 只有当前来源仍持有原份额时才签发一次出站前许可；查询原现金结果不需要伪造新的消费授权。 */
CREATE FUNCTION meton_ledger.original_alternative_cash_permit(route jsonb,ref uuid,proposal jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);d meton_ledger.refund_alternative_decisions;
    i meton_ledger.refund_alternative_intents;f jsonb;
BEGIN
    SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    IF context IS NULL OR d.choice IS DISTINCT FROM 'reserved' OR i.proposal IS DISTINCT FROM proposal OR
        proposal->'envelope' IS DISTINCT FROM context->'envelope' OR NOT meton_ledger.original_alternative_source_share(context,ref) THEN
        RETURN jsonb_build_object('state','source_restricted'); END IF;
    f:=jsonb_build_object('format',1,'scope',jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system),'proposal',proposal,'ticket',d.ticket,'validUntil',clock_timestamp()+interval '20 seconds');
    RETURN jsonb_build_object('state','source_ready','facts',f,'mac',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.alternative.io-source.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 先记录替代渠道的真实现金事实，随后复用原结清器；不同渠道身份不能伪装成原生微信退款。 */
CREATE FUNCTION meton_ledger.resolve_alternative_refund(route jsonb,ref uuid,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);i meton_ledger.refund_alternative_intents;
    d meton_ledger.refund_alternative_decisions;f jsonb:=proof->'facts';c jsonb:=f->'cash';s jsonb;digest bytea;
    r meton_ledger.cash_refunds;q meton_ledger.cash_refund_quotes;m public.meton_managed_creations;saved meton_ledger.refund_cash_confirmations;payment uuid;
BEGIN
    IF context IS NULL THEN RETURN 'original_unavailable'; END IF;
    SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF (proof->>'state' IN ('alternative_success','alternative_review')) IS NOT TRUE OR proof->>'state' IS DISTINCT FROM f->>'state'
        OR i.refund IS NULL OR d.choice IS DISTINCT FROM 'reserved'
        OR f->'scope' IS DISTINCT FROM s OR f->'proposal' IS DISTINCT FROM i.proposal OR i.proposal->'envelope' IS DISTINCT FROM context->'envelope'
        OR ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.cash.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified alternative cash' USING ERRCODE='42501'; END IF;
    IF c IS NOT NULL AND c<>'null'::jsonb THEN
        IF c->'payment' IS DISTINCT FROM i.proposal->'payment' OR (c->>'transaction'~'^[A-Za-z0-9_.:-]{1,120}$') IS NOT TRUE THEN
            RAISE EXCEPTION 'alternative payment identity differs' USING ERRCODE='42501'; END IF;
        digest:=sha256(convert_to(c::text,'UTF8'));
        IF encode(digest,'hex') IS DISTINCT FROM f->>'economicHash' THEN RAISE EXCEPTION 'alternative economic hash differs' USING ERRCODE='42501'; END IF;
        INSERT INTO meton_ledger.refund_alternative_cash VALUES(ref,digest,c) ON CONFLICT DO NOTHING;
    END IF;
    IF proof->>'state'='alternative_review' THEN
        IF (f->>'reviewHash'~'^[0-9a-f]{64}$') IS NOT TRUE THEN RAISE EXCEPTION 'alternative review evidence missing' USING ERRCODE='42501'; END IF;
        RETURN meton_ledger.record_refund_dispute(ref,decode(f->>'reviewHash','hex'),'alternative_cash_conflict',CASE WHEN c IS NULL OR c='null'::jsonb THEN 0 ELSE 1 END);
    END IF;
    IF c IS NULL OR c='null'::jsonb THEN RAISE EXCEPTION 'alternative success has no cash' USING ERRCODE='42501'; END IF;
    SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE refund_id=ref;
    SELECT h.* INTO STRICT q FROM meton_ledger.cash_refund_decisions x JOIN meton_ledger.cash_refund_quotes h USING(quote_id) WHERE x.refund_id=ref;
    SELECT * INTO STRICT m FROM public.meton_managed_creations WHERE source_marker=(context->>'marker')::uuid;
    IF r.part_id IS NOT NULL THEN SELECT payment_id INTO STRICT payment FROM meton_ledger.cash_parts WHERE part_id=r.part_id; END IF;
    -- 通用确认行保存真实替代付款对象；这里只复用原账务提交，绝不填造微信 refundID。
    INSERT INTO meton_ledger.refund_cash_confirmations(refund,envelope,cash,economic_hash) VALUES(ref,i.proposal->'envelope',c,digest) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT saved FROM meton_ledger.refund_cash_confirmations WHERE refund=ref;
    IF (saved.envelope,saved.cash,saved.economic_hash) IS DISTINCT FROM (i.proposal->'envelope',c,digest) OR r.phase='released' THEN
        RETURN meton_ledger.record_refund_dispute(ref,digest,'alternative_source_terminal_conflict',1); END IF;
    IF meton_ledger.refund_payment_disputed(m.source_marker,r.native_order,payment,r.legacy_cutoff) THEN RETURN 'review'; END IF;
    IF r.phase NOT IN ('cash_confirmed','settled') THEN
        UPDATE meton_ledger.cash_refunds SET phase='cash_confirmed',disposition_version=disposition_version+1 WHERE refund_id=ref;
        RETURN 'cash_confirmed'; END IF;
    RETURN meton_ledger.post_confirmed_refund(m,r,q,saved,payment);
END $$;

DO $view$
DECLARE body text:=pg_get_functiondef('meton_ledger.refund_aftercare_view(uuid,jsonb)'::regprocedure);
    point text:='''alternativeOrder'',i.proposal#>''{payment,order}''';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative projection changed'; END IF;
    EXECUTE replace(body,point,point||',''alternativePaid'',EXISTS(SELECT FROM meton_ledger.refund_alternative_cash WHERE refund=ref)');
END $view$;
REVOKE ALL ON FUNCTION meton_ledger.original_alternative_cash_permit(jsonb,uuid,jsonb),meton_ledger.resolve_alternative_refund(jsonb,uuid,jsonb) FROM PUBLIC;
