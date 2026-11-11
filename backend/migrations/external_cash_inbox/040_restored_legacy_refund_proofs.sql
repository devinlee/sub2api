-- 旧批准事实不随恢复换代改写。当前审核员须重新核对原终态、全部旧发送者及同一原清单，才可重签外层权限。
DO $restore$
DECLARE definition text:=pg_get_functiondef('meton_inbox.review_legacy_refund_return(jsonb,jsonb,text,jsonb)'::regprocedure);
    declaration constant text:='refs jsonb; seals jsonb:=';
    original_check constant text:='IF entry.marker IS NULL OR (entry.scope,entry.target,entry.manifest,entry.retirements,entry.closure_proofs) IS DISTINCT FROM (s,target,manifest,refs,seals) THEN';
    original_facts constant text:='facts:=jsonb_build_object(''format'',1,''scope'',entry.scope';
    seal constant text:='    RETURN jsonb_build_object(''state'',''proved'',''facts'',facts';
BEGIN
    IF cardinality(string_to_array(definition,declaration))<>2 OR cardinality(string_to_array(definition,original_check))<>2
        OR cardinality(string_to_array(definition,original_facts))<>2 OR cardinality(string_to_array(definition,seal))<>2 THEN
        RAISE EXCEPTION 'original historical clearance checks changed'; END IF;
    definition:=replace(definition,declaration,'original_policy meton_inbox.legacy_refund_deployments; '||declaration);
    definition:=replace(definition,original_check,$check$
    SELECT * INTO original_policy FROM meton_inbox.legacy_refund_deployments WHERE
        (deployment,source,epoch,provider_instance)=(entry.scope->>'deployment',entry.scope->>'source',(entry.scope->>'epoch')::bigint,p.provider_instance);
    IF entry.marker IS NULL OR original_policy.provider_instance IS NULL OR
        entry.scope-ARRAY['epoch','keyRef'] IS DISTINCT FROM s-ARRAY['epoch','keyRef'] OR
        (entry.scope->>'epoch')::bigint NOT BETWEEN 1 AND p.epoch OR
        (original_policy.channel,original_policy.cash_environment,original_policy.merchant,original_policy.app,original_policy.inventory,original_policy.inventory_evidence)
            IS DISTINCT FROM (p.channel,p.cash_environment,p.merchant,p.app,p.inventory,p.inventory_evidence) OR
        (entry.target,entry.manifest,entry.retirements,entry.closure_proofs) IS DISTINCT FROM (target,manifest,refs,seals) THEN
$check$);
    definition:=replace(definition,original_facts,'facts:=jsonb_build_object(''format'',1,''scope'',s');
    EXECUTE replace(definition,seal,$original$
    IF entry.scope IS DISTINCT FROM s THEN
        facts:=facts||jsonb_build_object('originalScope',entry.scope);
    END IF;
$original$||seal);
END $restore$;
