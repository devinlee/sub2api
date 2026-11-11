-- 混合资金账号沿已交接的最终关闭事实核销原赠送。现金、购买与模型占用仍由原算法处理。
ALTER FUNCTION meton_ledger.gift_state(uuid,uuid) RENAME TO gift_state_v277;
/** 只增加受限的赠送核销就绪状态，不能把存在购买或退款的账号标成 gift_only。 */
CREATE FUNCTION meton_ledger.gift_state(p_marker uuid,p_eligibility uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb:=meton_ledger.gift_state_v277(p_marker,p_eligibility);
    final meton_ledger.cash_closure_final_facts;s meton_ledger.cash_closure_scopes;
    stock numeric;native numeric;gift_held numeric;gift_refund numeric;
BEGIN
    IF result->>'state' NOT IN ('cash_review','settlement_pending') THEN RETURN result; END IF;
    SELECT f.* INTO final FROM meton_ledger.cash_closure_final_facts f JOIN meton_ledger.cash_closure_scopes c USING(closure_id)
        WHERE (c.owner->>'source_marker')::uuid=p_marker AND (f.identity_fact->>'giftEligibility')::uuid=p_eligibility;
    IF NOT FOUND THEN RETURN result; END IF;
    SELECT * INTO STRICT s FROM meton_ledger.cash_closure_scopes WHERE closure_id=final.closure_id;
    -- 恢复后的来源代次仍由原 gift_owner／恢复链验证；最终决定和赠送批次绝不随当前联系方式变化。
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_account_facts f WHERE f.source_marker=p_marker AND f.registration=s.registration AND
        f.lifecycle='closed' AND f.security_version=(final.identity_fact->>'securityVersion')::bigint AND
        f.recovery_version=(final.identity_fact->>'recoveryVersion')::bigint AND f.last_stop_version=f.security_version) THEN RETURN result; END IF;
    SELECT coalesce(sum(l.remaining),0),coalesce(sum(l.held) FILTER(WHERE g.eligibility=p_eligibility),0),
        coalesce(sum(l.refund_held) FILTER(WHERE g.eligibility=p_eligibility),0) INTO stock,gift_held,gift_refund
        FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event
        LEFT JOIN meton_ledger.registration_grants g ON g.event_id=e.event_id AND g.source_marker=p_marker WHERE e.source_marker=p_marker;
    SELECT balance INTO STRICT native FROM public.users WHERE id=(s.owner->>'remote_user')::bigint;
    IF stock<>native OR EXISTS(SELECT FROM meton_ledger.accounts a WHERE a.source_marker=p_marker AND NOT EXISTS(
        SELECT FROM meton_ledger.events e WHERE e.source_marker=p_marker AND e.sequence=a.last_sequence AND e.balance_after=native)) OR
        EXISTS(SELECT FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event
        WHERE e.source_marker=p_marker AND e.kind='grant' AND NOT EXISTS(SELECT FROM meton_ledger.registration_grants g
            WHERE g.event_id=e.event_id AND g.source_marker=p_marker AND g.eligibility=p_eligibility)) THEN
        RETURN result||jsonb_build_object('state','source_review'); END IF;
    IF gift_held<>0 OR gift_refund<>0 THEN RETURN result||jsonb_build_object('state','settlement_pending'); END IF;
    RETURN result||jsonb_build_object('state','gift_scope_ready');
END $$;

/** 原核销幂等键、原事件分配和恢复校验不变；只扩充已核对原最终决定的准入。 */
DO $reuse$
DECLARE signature text;body text;gate text:='NOT IN (''empty'',''gift_only'')';
    accepted text:='NOT IN (''empty'',''gift_only'',''gift_scope_ready'')';
    anchor text:='    status=meton_ledger.gift_state(p_marker,p_eligibility);';
BEGIN
    FOREACH signature IN ARRAY ARRAY[
        'meton_ledger.terminate_gift(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,uuid,bigint,bigint)',
        'meton_ledger.retire_gift_incoming(uuid)'] LOOP
        body:=pg_get_functiondef(signature::regprocedure);
        IF cardinality(string_to_array(body,gate))<>2 THEN RAISE EXCEPTION 'original gift termination gate changed'; END IF;
        body:=replace(body,gate,accepted);
        IF signature LIKE 'meton_ledger.terminate_gift(%' THEN
            IF cardinality(string_to_array(body,anchor))<>2 THEN RAISE EXCEPTION 'original gift decision gate changed'; END IF;
            -- 可用核销状态不能让其他最终事件借用它；逐一比对原关闭及原赠送明确确认。
            body:=replace(body,anchor,anchor||E'\n'||
                '    IF status->>''state''=''gift_scope_ready'' AND NOT EXISTS('||E'\n'||
                '        SELECT FROM meton_ledger.cash_closure_final_facts f JOIN meton_ledger.cash_closure_scopes c USING(closure_id)'||E'\n'||
                '        WHERE f.closure_id=p_decision AND (c.owner->>''source_marker'')::uuid=p_marker AND c.registration=p_registration'||E'\n'||
                '        AND f.identity_event=p_identity_event AND (f.identity_fact->>''giftEligibility'')::uuid=p_eligibility'||E'\n'||
                '        AND (f.identity_fact->>''securityVersion'')::bigint=p_security AND (f.identity_fact->>''recoveryVersion'')::bigint=p_identity_epoch) THEN'||E'\n'||
                '        RAISE EXCEPTION ''original cash closure gift decision required'' USING ERRCODE=''42501''; END IF;');
        END IF;
        EXECUTE body;
    END LOOP;
END $reuse$;
REVOKE ALL ON FUNCTION meton_ledger.gift_state_v277(uuid,uuid),meton_ledger.gift_state(uuid,uuid) FROM PUBLIC;
