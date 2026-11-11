-- 渠道通知描述的退款与原用户受理的退款分别保存。已验的通知只能限制原交易的履约，不能发钱或结清退款。
CREATE TABLE meton_ledger.cash_refund_observations(
    native_order bigint NOT NULL, source_marker uuid NOT NULL, channel text NOT NULL, cash_environment text NOT NULL, merchant_id text NOT NULL,
    transaction_id text NOT NULL, digest bytea NOT NULL CHECK(octet_length(digest)=32), facts jsonb NOT NULL,
    FOREIGN KEY(native_order,source_marker,channel,cash_environment,merchant_id)
        REFERENCES meton_ledger.cash_orders(native_order,source_marker,channel,cash_environment,merchant_id),
    PRIMARY KEY(native_order,transaction_id,digest)
);
REVOKE ALL ON meton_ledger.cash_refund_observations FROM PUBLIC;

-- 缺少本地退款或出现矛盾时只认已验的原商户订单。已绑定退款的旧证明继续可读。
DO $origin$
DECLARE def text:=pg_get_functiondef('meton_ledger.notification_origin(text,text,bigint,text,text,text,text,jsonb)'::regprocedure); condition text;
BEGIN
    FOREACH condition IN ARRAY ARRAY[
        'RAISE EXCEPTION ''original refund unavailable'' USING ERRCODE=''P0002'';',
        'RAISE EXCEPTION ''original refund differs'' USING ERRCODE=''22023'';',
        'RAISE EXCEPTION ''original refund payment differs'' USING ERRCODE=''22023'';'] LOOP
        IF cardinality(string_to_array(def,condition))<>2 THEN RAISE EXCEPTION 'original refund evidence changed'; END IF;
        def:=replace(def,condition,'RETURN result;');
    END LOOP;
    EXECUTE def;
END $origin$;

CREATE FUNCTION meton_ledger.observe_original_refund(deployment text,source_name text,generation bigint,origin jsonb,facts jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE o meton_ledger.cash_orders%ROWTYPE; actual jsonb; economic jsonb:=facts-'delivery'; pay uuid;
    bound_keys text[]:=ARRAY['payment','part','refund','refundIntent','refundOrder','basis','requestedFen','requestedUnits'];
BEGIN
    PERFORM meton_ledger.require_cash_writer(deployment,source_name,generation);
    IF (facts->>'kind'='refund' AND facts->>'state' IN ('SUCCESS','CLOSED','ABNORMAL')
        AND length(facts->>'transaction') BETWEEN 1 AND 64 AND length(facts->>'refundOrder') BETWEEN 1 AND 64
        AND length(facts->>'refundID') BETWEEN 1 AND 64 AND (facts->>'refundFen')::bigint BETWEEN 1 AND (facts->>'total')::bigint
        AND (facts->>'payerRefund')::bigint BETWEEN 0 AND least((facts->>'payerTotal')::bigint,(facts->>'refundFen')::bigint)) IS NOT TRUE THEN
        RAISE EXCEPTION 'verified refund facts required' USING ERRCODE='22023'; END IF;
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((origin->>'sourceMarker')::uuid));
    SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE intent_id=(origin->>'intent')::uuid FOR UPDATE;
    actual:=meton_ledger.notification_origin(deployment,source_name,generation,o.channel,o.cash_environment,o.merchant_id,o.app_id,facts);
    IF (actual-bound_keys) IS DISTINCT FROM (origin-bound_keys) THEN RAISE EXCEPTION 'refund original owner differs' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_ledger.cash_refund_observations VALUES(o.native_order,o.source_marker,o.channel,o.cash_environment,o.merchant_id,
        facts->>'transaction',sha256(convert_to(economic::text,'UTF8')),economic) ON CONFLICT DO NOTHING;
    SELECT payment_id INTO pay FROM meton_ledger.cash_payments WHERE native_order=o.native_order AND source_marker=o.source_marker
        AND channel_transaction=facts->>'transaction';
    IF FOUND THEN PERFORM meton_ledger.restrict_unposted_payment(pay); END IF;
    RETURN jsonb_build_object('state','review');
END $$;
REVOKE ALL ON FUNCTION meton_ledger.observe_original_refund(text,text,bigint,jsonb,jsonb) FROM PUBLIC;

DO $hold$
DECLARE observe_def text:=pg_get_functiondef('meton_ledger.observe_cash_payment(text,text,bigint,jsonb,jsonb)'::regprocedure);
    fulfil_def text:=pg_get_functiondef('meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)'::regprocedure);
    award constant text:='IF first_payment AND'; post_gate constant text:='IF p.order_fen<>o.price_fen OR';
BEGIN
    IF cardinality(string_to_array(observe_def,award))<>2 OR cardinality(string_to_array(fulfil_def,post_gate))<>2 THEN
        RAISE EXCEPTION 'original payment admission changed'; END IF;
    EXECUTE replace(observe_def,award,$sql$IF first_payment AND NOT EXISTS(SELECT FROM meton_ledger.cash_refund_observations signal
        WHERE signal.native_order=o.native_order AND signal.transaction_id=p.channel_transaction) AND$sql$);
    EXECUTE replace(fulfil_def,post_gate,$sql$IF EXISTS(SELECT FROM meton_ledger.cash_refund_observations signal
        WHERE signal.native_order=o.native_order AND signal.transaction_id=p.channel_transaction) OR p.order_fen<>o.price_fen OR$sql$);
END $hold$;
