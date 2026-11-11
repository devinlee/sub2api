-- 外部返还沿原退款已验证的账号、原付款和当前归档签章接回来源。这里仅追加核对事实，不改额度余额。
CREATE TABLE meton_ledger.cash_return_reviews(
    refund uuid NOT NULL REFERENCES meton_ledger.refund_gate_origins,
    evidence bytea NOT NULL CHECK(octet_length(evidence)=32),
    marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker),
    payment uuid REFERENCES meton_ledger.cash_payments, cutoff uuid,
    epoch bigint NOT NULL CHECK(epoch>0), snapshot jsonb NOT NULL, observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(refund,evidence), CHECK(num_nonnulls(payment,cutoff)=1),
    FOREIGN KEY(cutoff,marker) REFERENCES meton_ledger.legacy_balance_fences(cutoff,source_marker)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.cash_return_reviews
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_return_reviews ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.cash_return_reviews FROM PUBLIC;

/** 已验原退款证明才可进入本函数；重算原币种、返还合计和超额，不把核对记录当成扣款授权。 */
CREATE FUNCTION meton_ledger.capture_external_cash_review(
    g meton_ledger.refund_gate_origins,r meton_ledger.cash_refunds,pay uuid,generation bigint,facts jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE x jsonb:=facts->'cashExposure';e jsonb:=facts->'envelope';k jsonb:=e->'cash';s jsonb:=e->'scope';
    hash bytea;total numeric;cap numeric;original bytea;
BEGIN
    IF x IS NULL THEN RETURN; END IF;
    hash:=sha256(convert_to(x::text,'UTF8'));
    original:=sha256(convert_to(jsonb_build_array(s->>'channel',s->>'cashEnvironment',s->>'merchant',s->>'app',k->>'order',k->>'transaction')::text,'UTF8'));
    IF (x->'format'='1'::jsonb AND facts->>'cashExposureHash'=encode(hash,'hex') AND x->>'original'=encode(original,'hex')
        AND x->>'currency'='CNY' AND x->>'evidenceHash'~'^[a-f0-9]{64}$'
        AND x->>'externalEvents'~'^[1-9][0-9]{0,17}$' AND x->>'ambiguousExternalEvents'~'^[0-9]{1,18}$'
        AND x->>'ambiguousRefundEvents'~'^[0-9]{1,18}$'
        AND x->>'knownExternalFen'~'^[0-9]{1,30}$' AND x->>'knownRefundFen'~'^[0-9]{1,30}$'
        AND x->>'knownReturnedFen'~'^[0-9]{1,30}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid original external cash review' USING ERRCODE='42501'; END IF;
    total:=(x->>'knownExternalFen')::numeric+(x->>'knownRefundFen')::numeric;
    IF total IS DISTINCT FROM (x->>'knownReturnedFen')::numeric THEN
        RAISE EXCEPTION 'cash return sum differs' USING ERRCODE='42501'; END IF;
    IF coalesce((k->>'payerTotalUnrecorded')::boolean,false) THEN
        -- 历史账只有订单金额时不能冒充付款人的实付，更不能把无法判定的差额写成零。
        IF x->'payerCapFen' IS DISTINCT FROM 'null'::jsonb OR x->'knownExcessFen' IS DISTINCT FROM 'null'::jsonb THEN
            RAISE EXCEPTION 'original payer amount unknown' USING ERRCODE='42501'; END IF;
    ELSE
        cap:=(k->>'payerTotal')::numeric;
        IF (x->>'payerCapFen'~'^[0-9]{1,19}$' AND x->>'knownExcessFen'~'^[0-9]{1,30}$'
            AND cap=(x->>'payerCapFen')::numeric AND greatest(total-cap,0)=(x->>'knownExcessFen')::numeric) IS NOT TRUE THEN
            RAISE EXCEPTION 'original cash cap differs' USING ERRCODE='42501'; END IF;
    END IF;
    INSERT INTO meton_ledger.cash_return_reviews(refund,evidence,marker,payment,cutoff,epoch,snapshot)
        VALUES(r.refund_id,hash,g.marker,pay,r.legacy_cutoff,generation,x) ON CONFLICT DO NOTHING;
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_return_reviews v WHERE (v.refund,v.evidence,v.marker,v.payment,v.cutoff,v.snapshot)
        IS NOT DISTINCT FROM (r.refund_id,hash,g.marker,pay,r.legacy_cutoff,x)) THEN
        RAISE EXCEPTION 'original cash review ownership differs' USING ERRCODE='23505'; END IF;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.capture_external_cash_review(
    meton_ledger.refund_gate_origins,meton_ledger.cash_refunds,uuid,bigint,jsonb) FROM PUBLIC;

DO $capture$
DECLARE body text:=pg_get_functiondef('meton_ledger.resolve_original_refund(jsonb,uuid,jsonb)'::regprocedure);
    point text:='RETURN meton_ledger.record_refund_dispute(ref,decode(facts->>''reviewHash'',''hex''),''channel_conflict'',(facts->>''confirmedCashVariants'')::integer);';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original dispute resolution changed'; END IF;
    EXECUTE replace(body,point,'PERFORM meton_ledger.capture_external_cash_review(g,r,payment,a.epoch,facts); '||point);
END $capture$;
