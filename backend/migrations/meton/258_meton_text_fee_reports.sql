-- 原费项报告永久关联 S2-06 的请求。累计观察可以乱序到达；它不产生扣款、释放或新的派发资格。
CREATE TABLE meton_ledger.text_fee_reports (
    event_id uuid PRIMARY KEY CHECK (event_id<>'00000000-0000-0000-0000-000000000000'),
    request_id uuid NOT NULL REFERENCES meton_ledger.text_requests,
    item_id uuid NOT NULL CHECK (item_id<>'00000000-0000-0000-0000-000000000000'),
    revision integer NOT NULL CHECK (revision>0),
    state text NOT NULL CHECK (state IN ('observed','final','revised')),
    amount numeric(20,8) NOT NULL CHECK (amount BETWEEN 0 AND 999999999999.99999999),
    previous_event uuid, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (request_id,item_id,revision), UNIQUE (request_id,item_id,event_id),
    FOREIGN KEY (request_id,item_id,previous_event) REFERENCES meton_ledger.text_fee_reports(request_id,item_id,event_id),
    CHECK (CASE WHEN state='revised' THEN revision>1 AND previous_event IS NOT NULL AND previous_event<>event_id ELSE previous_event IS NULL END)
);
CREATE TRIGGER immutable_text_fee_report BEFORE UPDATE OR DELETE ON meton_ledger.text_fee_reports
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();

-- 回执沿用 S2-03 的费用协议。用户、账户与计价版本只能取自原受理，不从传入的报告正文拼接。
CREATE FUNCTION meton_ledger.find_text_fee(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
        p_request uuid,p_item uuid,p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('version',1,
        'origin',jsonb_build_object('environment',h.environment,'source',h.source,'user',h.meton_user,'account',h.account,
            'source_marker',h.source_marker,'caller',h.caller,'operation_id',h.operation_id,'source_request_id',h.request_id),
        'item',jsonb_build_object('charge_item_id',r.item_id,'event_id',r.event_id,'revision',r.revision,'state',r.state,
            'price_version',h.price_version,'unit',h.unit,'amount',r.amount::text,'previous_event_id',r.previous_event))
    FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation) h
    JOIN meton_ledger.text_fee_reports r ON r.request_id=h.request_id
    WHERE h.request_id=p_request AND r.item_id=p_item AND r.event_id=p_event
$$;

CREATE FUNCTION meton_ledger.observe_text_fee(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
        p_request uuid,p_item uuid,p_event uuid,p_revision integer,p_price text,p_unit text,p_amount text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; receipt jsonb;
BEGIN
    PERFORM meton_ledger.lock_text_owner(p_env,p_source,p_epoch,p_user,p_account,p_marker);
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request OR h.epoch_at_accept<>p_epoch OR h.state<>'dispatch_claimed' THEN
        RAISE EXCEPTION 'original dispatched request unconfirmed' USING ERRCODE='55000';
    END IF;
    IF num_nulls(p_item,p_event,p_revision,p_price,p_unit,p_amount)>0 OR '00000000-0000-0000-0000-000000000000'::uuid IN (p_item,p_event)
        OR p_revision<1 OR p_amount !~ '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$' THEN
        RAISE EXCEPTION 'invalid observed fee' USING ERRCODE='22023';
    END IF;
    IF (p_price,p_unit) IS DISTINCT FROM (h.price_version,h.unit) THEN RAISE EXCEPTION 'not original fee price or unit' USING ERRCODE='23505'; END IF;
    INSERT INTO meton_ledger.text_fee_reports(event_id,request_id,item_id,revision,state,amount)
        VALUES(p_event,p_request,p_item,p_revision,'observed',p_amount::numeric)
        ON CONFLICT DO NOTHING;
    receipt:=meton_ledger.find_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_event);
    IF receipt IS NULL OR receipt->'item'->>'state'<>'observed' OR receipt->'item'->>'amount'<>p_amount
        OR (receipt->'item'->>'revision')::integer<>p_revision THEN
        RAISE EXCEPTION 'original fee event or revision conflict' USING ERRCODE='23505';
    END IF;
    RETURN receipt;
END $$;
REVOKE ALL ON TABLE meton_ledger.text_fee_reports FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.find_text_fee(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid),
    meton_ledger.observe_text_fee(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,integer,text,text,text) FROM PUBLIC;
