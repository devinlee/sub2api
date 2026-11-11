-- 当前证明包含截点外原申请的原因。核验摘要不改，已批准的原材料不会因恢复签章更新而变成另一份申请。
DO $reason$
DECLARE body text:=pg_get_functiondef('meton_inbox.original_refund_aftercare_result(jsonb,uuid)'::regprocedure);
    point text:='facts:=jsonb_build_object(''format'',1,''scope'',scope,''envelope'',b.envelope,';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'aftercare result changed'; END IF;
    EXECUTE replace(body,point,point||'''reason'',b.reason,');
END $reason$;
