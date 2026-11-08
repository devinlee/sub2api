-- 原创建和原调用唯一定位终局；查询角色不接收调用方自报的来源请求号或费用事件号。
CREATE FUNCTION meton_ledger.read_text_result(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_caller text,p_operation uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE admission jsonb; original jsonb; fee jsonb; result jsonb; o jsonb;
BEGIN
    admission:=meton_ledger.read_text_reference(p_env,p_source,p_epoch,p_creation,p_caller,p_operation,NULL);
    IF admission IS NULL THEN RETURN NULL; END IF;
    o:=admission->'origin';
    original:=meton_ledger.find_execution_result(p_env,p_source,p_epoch,(o->>'user')::uuid,(o->>'account')::uuid,
        (o->>'source_marker')::uuid,p_caller,p_operation,(o->>'source_request_id')::uuid);
    IF original IS NOT NULL THEN
        IF original->'posting' IS NOT NULL AND original->'posting'<>'null'::jsonb THEN
            fee:=jsonb_build_object('reference',original->'posting'->'report',
                'funded',original->'posting'->'funded','uncovered',original->'posting'->'uncovered');
        END IF;
        -- 仅投影有界元数据。正文、响应 ID、正文摘要和各个资金来源分配不进入跨服务回执。
        result:=jsonb_build_object('observation_id',original->'event_id',
            'execution',original->'observation'->'execution','usage',original->'observation'->'usage','fee',fee);
    END IF;
    RETURN jsonb_build_object('version',1,'admission',admission,'result',result);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_text_result(text,text,bigint,uuid,text,uuid) FROM PUBLIC;
