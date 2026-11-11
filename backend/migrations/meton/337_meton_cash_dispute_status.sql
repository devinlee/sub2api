-- 争议进度是原资金的投影，不成为第二个余额或现金权威。
CREATE TABLE meton_ledger.cash_dispute_statuses(
    dispute uuid NOT NULL,revision bigint NOT NULL CHECK(revision>0),original bytea NOT NULL CHECK(octet_length(original)=32),
    marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker),native_order bigint NOT NULL REFERENCES public.payment_orders(id),
    value jsonb NOT NULL,epoch bigint NOT NULL,recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(dispute,revision)
);
CREATE INDEX cash_dispute_original_status ON meton_ledger.cash_dispute_statuses(marker,native_order,revision DESC);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.cash_dispute_statuses FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_dispute_statuses ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.cash_dispute_statuses FROM PUBLIC;

/** 当前来源证明原付款归属；是否需要争议由独立现金事实决定，不凭来访者自报的用户建案。 */
CREATE FUNCTION meton_ledger.prepare_cash_dispute_origin(route jsonb,trade text,txn text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    e jsonb:=meton_ledger.original_cash_review_origin(route,trade,txn);f jsonb;
BEGIN
    IF e IS NULL THEN RETURN jsonb_build_object('state','original_unavailable'); END IF;
    f:=jsonb_build_object('format',1,'scope',jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,
        'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system),'origin',e,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','ready','facts',f,'mac',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.cash.dispute.origin.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 核对结果按原账号、原付款和版本追加；过时结果可留证，但不能覆盖新版或解除原款限制。 */
CREATE FUNCTION meton_ledger.apply_cash_dispute_status(route jsonb,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);f jsonb:=proof->'facts';v jsonb:=f->'value';
    e jsonb:=f->'origin';actual jsonb;s jsonb;key bytea;owner jsonb;saved meton_ledger.cash_dispute_statuses;exposure jsonb;
BEGIN
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF proof->>'state' IS DISTINCT FROM 'dispute_proved' OR f->>'format' IS DISTINCT FROM '1' OR f->'scope' IS DISTINCT FROM s OR
        ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.cash.dispute.status.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'current original dispute proof required' USING ERRCODE='42501'; END IF;
    actual:=meton_ledger.original_cash_review_origin(route,e#>>'{cash,order}',e#>>'{cash,transaction}');
    IF actual IS NULL THEN RETURN 'original_unavailable'; END IF;
    IF e IS DISTINCT FROM actual THEN RAISE EXCEPTION 'dispute original owner differs' USING ERRCODE='42501'; END IF;
    key:=sha256(convert_to(jsonb_build_array(e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',e#>>'{scope,app}',e#>>'{cash,order}',e#>>'{cash,transaction}')::text,'UTF8'));
    owner:=jsonb_build_array(e#>'{owner,user}',e#>'{owner,account}',e#>'{owner,source_marker}',e#>'{target,nativeOrder}',e#>'{target,payment}',e#>'{target,cutoff}');
    IF (v->>'format'='1' AND v->>'id'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND v->>'revision'~'^[1-9][0-9]{0,17}$'
        AND v->>'original'=encode(key,'hex') AND v->'owner'=owner AND v->>'financialState'='restricted'
        AND v->>'state' IN ('pending_review','reviewing','awaiting_material','reviewed_restricted')) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid original dispute status' USING ERRCODE='42501'; END IF;
    exposure:=meton_ledger.checked_cash_exposure(e,jsonb_build_object('cashExposure',v->'cashExposure','cashExposureHash',v->'cashHash'));
    INSERT INTO meton_ledger.cash_dispute_statuses(dispute,revision,original,marker,native_order,value,epoch)
        VALUES((v->>'id')::uuid,(v->>'revision')::bigint,key,(e#>>'{owner,source_marker}')::uuid,(e#>>'{target,nativeOrder}')::bigint,v,a.epoch) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT saved FROM meton_ledger.cash_dispute_statuses WHERE (dispute,revision)=((v->>'id')::uuid,(v->>'revision')::bigint);
    IF (saved.original,saved.marker,saved.native_order,saved.value) IS DISTINCT FROM (key,(e#>>'{owner,source_marker}')::uuid,(e#>>'{target,nativeOrder}')::bigint,v) THEN
        RAISE EXCEPTION 'dispute revision reused' USING ERRCODE='23505'; END IF;
    RETURN CASE WHEN EXISTS(SELECT FROM meton_ledger.cash_dispute_statuses x WHERE x.dispute=saved.dispute AND x.revision>saved.revision) THEN 'superseded' ELSE 'recorded' END;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.prepare_cash_dispute_origin(jsonb,text,text),meton_ledger.apply_cash_dispute_status(jsonb,jsonb) FROM PUBLIC;
