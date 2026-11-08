-- 原注销事实不可换代；当前权限必须另证完整原账号恢复链。
CREATE FUNCTION meton_ledger.require_gift_termination_epoch(t meton_ledger.gift_terminations,p_epoch bigint)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; proof public.meton_recovery_successions%ROWTYPE; expected bigint;
BEGIN
    IF t.decision IS NULL OR p_epoch IS NULL OR p_epoch<t.epoch THEN
        RAISE EXCEPTION 'original gift termination epoch required' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.gift_owner(t.environment,t.source,p_epoch,t.meton_user,t.account,t.creation,t.dispatch,t.remote_user,t.source_marker);
    IF p_epoch=t.epoch THEN RETURN; END IF;
    -- 可以伪造恢复证明的身份不能同时取得历史资金权；不以 SECURITY DEFINER 的所有者代替实际调用者。
    IF has_any_column_privilege(session_user,'public.meton_recovery_successions','INSERT,UPDATE') OR
       has_table_privilege(session_user,'public.meton_recovery_successions','DELETE,TRUNCATE,TRIGGER') THEN
        RAISE EXCEPTION 'recovery writer cannot retire historical gifts' USING ERRCODE='42501'; END IF;
    expected=t.epoch;
    WHILE expected<p_epoch LOOP
        SELECT * INTO proof FROM public.meton_recovery_successions WHERE source_marker=t.source_marker AND previous_epoch=expected FOR SHARE;
        IF NOT FOUND OR proof.next_epoch>p_epoch OR proof.next_epoch<=expected OR
           (proof.environment,proof.source,proof.meton_user,proof.account,proof.operation,proof.dispatch,proof.remote_user,proof.source_marker)
              IS DISTINCT FROM (t.environment,t.source,t.meton_user,t.account,t.creation,t.dispatch,t.remote_user,t.source_marker) THEN
            RAISE EXCEPTION 'continuous original gift recovery required' USING ERRCODE='55000'; END IF;
        expected=proof.next_epoch;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION meton_ledger.retire_gift_incoming(p_event uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE e meton_ledger.events%ROWTYPE; t meton_ledger.gift_terminations%ROWTYPE; part record; current_epoch bigint;
BEGIN
    SELECT * INTO STRICT e FROM meton_ledger.events WHERE event_id=p_event;
    IF e.amount<=0 OR e.kind NOT IN ('grant','text_revision','text_correction') THEN RETURN; END IF;
    SELECT * INTO t FROM meton_ledger.gift_terminations WHERE source_marker=e.source_marker;
    IF NOT FOUND OR e.sequence<=t.cutoff_sequence THEN RETURN; END IF;
    -- 只借当前栅栏取得权限，原核销决定、原原因事件与批次幂等键保持；失败回滚整笔迟到返还。
    SELECT epoch INTO current_epoch FROM public.meton_managed_fence WHERE singleton AND enabled
        AND environment=t.environment AND source=t.source FOR SHARE;
    PERFORM meton_ledger.require_gift_termination_epoch(t,current_epoch);
    IF meton_ledger.gift_state(t.source_marker,t.eligibility)->>'state' NOT IN ('empty','gift_only') THEN RETURN; END IF;
    FOR part IN SELECT * FROM meton_ledger.gift_incoming_parts(e.event_id) LOOP
        IF EXISTS(SELECT FROM meton_ledger.registration_grants g WHERE g.event_id=part.credit AND g.source_marker=t.source_marker AND g.eligibility=t.eligibility) THEN
            PERFORM meton_ledger.retire_gift_part(t.decision,part.credit,e.event_id,part.quantity);
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION meton_ledger.find_restored_gift_termination(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t meton_ledger.gift_terminations%ROWTYPE;
BEGIN
    IF p_epoch IS NULL OR p_original_epoch IS NULL OR p_epoch<=p_original_epoch THEN
        RAISE EXCEPTION 'explicit historical gift termination required' USING ERRCODE='22023'; END IF;
    SELECT * INTO t FROM meton_ledger.gift_terminations WHERE decision=p_decision;
    IF NOT FOUND OR (t.environment,t.source,t.epoch,t.meton_user,t.account,t.creation,t.dispatch,t.remote_user,t.source_marker,t.eligibility)
        IS DISTINCT FROM (p_env,p_source,p_original_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility) THEN
        RAISE EXCEPTION 'original gift termination scope unavailable' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_gift_termination_epoch(t,p_epoch);
    RETURN jsonb_build_object('environment',t.environment,'source',t.source,'epoch',t.epoch,'authority_epoch',p_epoch,'user',t.meton_user,'account',t.account,
        'creation',t.creation,'dispatch',t.dispatch,'remote_user',t.remote_user,'source_marker',t.source_marker,'eligibility',t.eligibility,
        'funds',meton_ledger.gift_state(t.source_marker,t.eligibility),'termination',to_jsonb(t),
        'retired',coalesce((SELECT sum(amount) FROM meton_ledger.gift_retirements WHERE decision=t.decision),0)::numeric(20,8)::text,
        'effects',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.effect) FROM meton_ledger.gift_retirements r WHERE r.decision=t.decision),'[]'::jsonb));
END $$;

CREATE FUNCTION meton_ledger.reconcile_restored_gift_termination(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_original_epoch bigint,p_decision uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE original jsonb; e record;
BEGIN
    original=meton_ledger.find_restored_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,p_original_epoch,p_decision);
    FOR e IN SELECT event_id FROM meton_ledger.events WHERE source_marker=p_marker AND sequence>(original->'termination'->>'cutoff_sequence')::bigint
        AND amount>0 ORDER BY sequence LOOP
        PERFORM meton_ledger.retire_gift_incoming(e.event_id);
    END LOOP;
    RETURN meton_ledger.find_restored_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,p_original_epoch,p_decision);
END $$;

-- 不发布运行权限。专用读身份只能查原事实；接续身份仍不能创建最终决定或任意改余额。
REVOKE ALL ON FUNCTION meton_ledger.require_gift_termination_epoch(meton_ledger.gift_terminations,bigint),
    meton_ledger.retire_gift_incoming(uuid),
    meton_ledger.find_restored_gift_termination(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid),
    meton_ledger.reconcile_restored_gift_termination(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,bigint,uuid) FROM PUBLIC;
