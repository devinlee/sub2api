-- 原创建和原调用定位发送裁决；prepared 是当前观察，不能用它代替取消事务的未执行证明。
CREATE FUNCTION meton_ledger.read_text_execution(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_caller text,p_operation uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admission jsonb; decision text;
BEGIN
    admission:=meton_ledger.read_text_reference(p_env,p_source,p_epoch,p_creation,p_caller,p_operation,NULL);
    IF admission IS NULL THEN RETURN NULL; END IF;
    SELECT state INTO decision FROM meton_ledger.text_send_decisions
        WHERE request_id=(admission->'origin'->>'source_request_id')::uuid;
    RETURN jsonb_build_object('version',1,'admission',admission,'state',coalesce(decision,'prepared'));
END $$;

-- 只包装已有取消／派发条件事务，不直接写余额或预占；缺原请求时仍返回未知，不能承诺阻断尚未到达的受理。
CREATE FUNCTION meton_ledger.cancel_original_text(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_caller text,p_operation uuid,p_expected jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admission jsonb; o jsonb; receipt meton_ledger.text_hold_receipt;
BEGIN
    admission:=meton_ledger.read_text_reference(p_env,p_source,p_epoch,p_creation,p_caller,p_operation,NULL);
    IF admission IS NULL THEN RETURN NULL; END IF;
    -- 取消者须携带已核对的完整原受理。恢复后即使路径 ID 重用，旧请求也不能改作用于另一份来源记录。
    IF p_expected IS DISTINCT FROM admission THEN RAISE EXCEPTION 'original cancellation context changed' USING ERRCODE='42501'; END IF;
    o:=admission->'origin';
    SELECT * INTO receipt FROM meton_ledger.cancel_unsent_text(p_env,p_source,p_epoch,(o->>'user')::uuid,(o->>'account')::uuid,
        (o->>'source_marker')::uuid,p_caller,p_operation,(o->>'source_request_id')::uuid);
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('version',1,'admission',admission,'state',receipt.state);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_text_execution(text,text,bigint,uuid,text,uuid),
    meton_ledger.cancel_original_text(text,text,bigint,uuid,text,uuid,jsonb) FROM PUBLIC;
