-- 原退款和无退款绑定的原付款继续共用同一核对算法；格式 1 历史证据保持可读，格式 2 明确包含替代现金。
DO $sum$
DECLARE body text:=pg_get_functiondef('meton_ledger.checked_cash_exposure(jsonb,jsonb)'::regprocedure);point text;
BEGIN
    point:='x->''format''=''1''::jsonb';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'cash exposure format changed'; END IF;
    body:=replace(body,point,'x->''format'' IN (''1''::jsonb,''2''::jsonb)');
    point:='x->>''externalEvents''~''^[1-9][0-9]{0,17}$''';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'external event count changed'; END IF;
    body:=replace(body,point,$new$x->>'externalEvents'~'^[0-9]{1,18}$' AND
        (x->'format'='1'::jsonb AND (x->>'externalEvents')::numeric>0 OR x->'format'='2'::jsonb AND
            x->>'alternativeEvents'~'^[0-9]{1,18}$' AND x->>'ambiguousAlternativeEvents'~'^[0-9]{1,18}$'
            AND x->>'knownAlternativeFen'~'^[0-9]{1,30}$')$new$);
    point:='total:=(x->>''knownExternalFen'')::numeric+(x->>''knownRefundFen'')::numeric;';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'cash exposure sum changed'; END IF;
    EXECUTE replace(body,point,'total:=(x->>''knownExternalFen'')::numeric+(x->>''knownRefundFen'')::numeric+'
        ||'CASE WHEN x->''format''=''2''::jsonb THEN (x->>''knownAlternativeFen'')::numeric ELSE 0 END;');
END $sum$;

DO $capture$
DECLARE body text:=pg_get_functiondef('meton_ledger.resolve_alternative_refund(jsonb,uuid,jsonb)'::regprocedure);point text;
BEGIN
    point:='r meton_ledger.cash_refunds;q meton_ledger.cash_refund_quotes;';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative review declaration changed'; END IF;
    body:=replace(body,point,'g meton_ledger.refund_gate_origins; '||point);
    point:='RETURN meton_ledger.record_refund_dispute(ref,decode(f->>''reviewHash'',''hex''),''alternative_cash_conflict''';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative cash review capture changed'; END IF;
    EXECUTE replace(body,point,$new$SELECT * INTO STRICT g FROM meton_ledger.refund_gate_origins WHERE refund=ref;
        SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE refund_id=ref;
        IF r.part_id IS NOT NULL THEN SELECT payment_id INTO STRICT payment FROM meton_ledger.cash_parts WHERE part_id=r.part_id; END IF;
        PERFORM meton_ledger.capture_external_cash_review(g,r,payment,a.epoch,
            jsonb_build_object('envelope',i.proposal->'envelope','cashExposure',f->'cashExposure','cashExposureHash',f->'cashExposureHash'));
        $new$||point);
END $capture$;
