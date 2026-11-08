-- 供应方返还的是供应成本。其币种、原凭证和金额独立保存，不写用户资金流水或批次。
CREATE TABLE meton_ledger.supplier_cost_returns (
    environment text NOT NULL, source text NOT NULL, provider text COLLATE "C" NOT NULL,
    reference text COLLATE "C" NOT NULL,
    request_id uuid NOT NULL, item_id uuid NOT NULL, original_report uuid NOT NULL,
    currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'),
    amount numeric(20,8) NOT NULL CHECK(amount>0 AND amount<=999999999999.99999999),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(environment,source,provider,reference),
    CHECK(provider ~ '^[A-Za-z0-9_.-]{1,120}$' AND reference ~ '^[A-Za-z0-9_.:/-]{1,160}$'),
    FOREIGN KEY(request_id,item_id,original_report) REFERENCES meton_ledger.text_fee_reports(request_id,item_id,event_id)
);
CREATE TRIGGER immutable_cost_return BEFORE UPDATE OR DELETE ON meton_ledger.supplier_cost_returns
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();

CREATE FUNCTION meton_ledger.find_supplier_return(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,
    p_operation uuid,p_request uuid,p_item uuid,p_report uuid,p_provider text,p_reference text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('origin',f.report->'origin','item',c.item_id,'original_report',c.original_report,'provider',c.provider,
                              'reference',c.reference,'currency',c.currency,'amount',c.amount::text)
    FROM meton_ledger.supplier_cost_returns c
    CROSS JOIN LATERAL (SELECT meton_ledger.find_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,
                                                          p_request,p_item,p_report) AS report) f
    WHERE (c.environment,c.source,c.provider,c.reference)=(p_env,p_source,p_provider,p_reference) AND
          (c.request_id,c.item_id,c.original_report)=(p_request,p_item,p_report) AND f.report IS NOT NULL
$$;

CREATE FUNCTION meton_ledger.record_supplier_return(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,
    p_operation uuid,p_request uuid,p_item uuid,p_report uuid,p_provider text,p_reference text,p_currency text,p_amount text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb;
BEGIN
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF num_nulls(p_item,p_report,p_provider,p_reference,p_currency,p_amount)>0
        OR p_provider !~ '^[A-Za-z0-9_.-]{1,120}$' OR p_reference !~ '^[A-Za-z0-9_.:/-]{1,160}$'
        OR p_currency !~ '^[A-Z]{3}$' OR p_amount !~ '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$' OR p_amount='0.00000000' THEN
        RAISE EXCEPTION 'invalid supplier cost evidence' USING ERRCODE='22023';
    END IF;
    IF meton_ledger.find_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_report) IS NULL THEN
        RAISE EXCEPTION 'unconfirmed original fee' USING ERRCODE='55000';
    END IF;
    -- 去重取供应商的原结算行号，通知投递号和确认时的会话均不能派生第二笔。
    INSERT INTO meton_ledger.supplier_cost_returns(environment,source,provider,reference,request_id,item_id,original_report,currency,amount)
        VALUES(p_env,p_source,p_provider,p_reference,p_request,p_item,p_report,p_currency,p_amount::numeric) ON CONFLICT DO NOTHING;
    result:=meton_ledger.find_supplier_return(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_report,p_provider,p_reference);
    IF result IS NULL OR (result->>'currency',result->>'amount') IS DISTINCT FROM (p_currency,p_amount) THEN
        RAISE EXCEPTION 'supplier cost reference conflict' USING ERRCODE='23505';
    END IF;
    RETURN result;
END $$;
REVOKE ALL ON TABLE meton_ledger.supplier_cost_returns FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.find_supplier_return(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,text,text),
    meton_ledger.record_supplier_return(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,text,text,text,text) FROM PUBLIC;
