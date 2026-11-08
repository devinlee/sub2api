-- 升级只核对已经结清的原记录；新规则遇到历史冲突时整次迁移回滚，留给原事项复核。
LOCK TABLE meton_ledger.text_result_resolutions IN SHARE MODE;

CREATE OR REPLACE FUNCTION meton_ledger.check_text_resolution_observation(p_request uuid,p_prior uuid,p_hash text,p_spec jsonb,p_observation jsonb)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE prior jsonb; known jsonb; reported jsonb;
BEGIN
    SELECT c.observation INTO prior FROM meton_ledger.text_completions c JOIN meton_ledger.text_transports t USING(request_id)
        JOIN meton_ledger.text_executions e USING(request_id)
        WHERE c.request_id=p_request AND c.event_id=p_prior AND t.context_hash=p_hash AND e.spec=p_spec;
    IF NOT FOUND OR prior->>'fee_ready' IS DISTINCT FROM 'false' OR prior->>'response_id'='' THEN
        RAISE EXCEPTION 'original unresolved response evidence required' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.validate_text_observation(p_spec,p_observation);
    IF p_observation->>'response_id' IS DISTINCT FROM prior->>'response_id' OR
        p_observation->>'fee_ready' IS DISTINCT FROM 'true' OR p_observation->>'execution'='unknown' OR
        p_observation->>'read_end'<>'eof' OR
        (prior->>'terminal'<>'' AND (p_observation->>'terminal',p_observation->>'execution') IS DISTINCT FROM
                                   (prior->>'terminal',prior->>'execution')) THEN
        RAISE EXCEPTION 'incomplete or conflicting original result proof' USING ERRCODE='22023'; END IF;
    known:=prior->'usage'; reported:=p_observation->'usage';
    IF prior->>'terminal'<>'' AND jsonb_typeof(known)='object' AND (
        (known->'input',known->'output') IS DISTINCT FROM (reported->'input',reported->'output') OR
        (jsonb_typeof(known->'cached')='number' AND known->'cached' IS DISTINCT FROM reported->'cached')
    ) THEN
        RAISE EXCEPTION 'conflicting original terminal usage' USING ERRCODE='22023'; END IF;
END $$;

-- 原凭证登记、执行和关闭期间的恢复提交本已共用此函数，继续沿原身份复验。
DO $migration$
BEGIN
    PERFORM meton_ledger.check_text_resolution_observation(p.request_id,p.prior_event,p.context_hash,e.spec,p.observation)
      FROM meton_ledger.text_result_resolutions r
      JOIN meton_ledger.text_result_proofs p ON p.evidence_id=r.evidence_id AND p.request_id=r.request_id
      JOIN meton_ledger.text_completions c ON c.event_id=p.prior_event AND c.request_id=p.request_id
      JOIN meton_ledger.text_executions e ON e.request_id=p.request_id
      WHERE c.observation->>'terminal'<>'' AND jsonb_typeof(c.observation->'usage')='object';
END $migration$;
