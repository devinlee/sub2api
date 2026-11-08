-- 查询权限只认原托管创建、原调用和原事件。调用者不能自报远端用户、来源标记或费项来改变归属。
CREATE FUNCTION meton_ledger.read_text_reference(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_caller text,p_operation uuid,p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT CASE WHEN p_event IS NULL THEN jsonb_build_object(
        'version',1,
        'origin',jsonb_build_object('environment',h.environment,'source',h.source,'source_marker',h.source_marker,
            'user',h.meton_user,'account',h.account,'caller',h.caller,'operation_id',h.operation_id,'source_request_id',h.request_id),
        'accepted_epoch',h.epoch_at_accept,
        'request',jsonb_build_object('protocol',h.protocol,'model',h.model,'digest_version',h.digest_version,
            'input_digest',h.input_digest,'input_bound',h.input_bound,'output_bound',h.output_bound),
        'pricing',jsonb_build_object('version',h.price_version,'unit',h.unit,'quote',h.quote))
    ELSE meton_ledger.find_text_fee(p_env,p_source,p_epoch,m.meton_user,m.account,m.source_marker,p_caller,p_operation,
        h.request_id,r.item_id,r.event_id) END
    FROM public.meton_managed_creations m
    CROSS JOIN LATERAL meton_ledger.find_text_hold(p_env,p_source,p_epoch,m.meton_user,m.account,m.source_marker,p_caller,p_operation) h
    LEFT JOIN meton_ledger.text_fee_reports r ON p_event IS NOT NULL AND r.request_id=h.request_id AND r.event_id=p_event
    WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND m.operation=p_creation
        AND p_caller IN ('meton.chat.v1','meton.oc07.v1') AND (p_event IS NULL OR r.event_id IS NOT NULL)
$$;
REVOKE ALL ON FUNCTION meton_ledger.read_text_reference(text,text,bigint,uuid,text,uuid,uuid) FROM PUBLIC;
