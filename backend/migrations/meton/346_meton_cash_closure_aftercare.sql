-- 账号最终关闭只交接原事项的售后责任，不写现金终态、不释放占用，也不授予普通账号权限。
CREATE TABLE meton_ledger.cash_closure_aftercare_policies(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),
    responsible_ref text NOT NULL CHECK(responsible_ref~'^[a-z0-9][a-z0-9._/-]{0,127}$'),
    PRIMARY KEY(deployment,source,epoch)
);
CREATE TABLE meton_ledger.cash_closure_final_facts(
    closure_id uuid PRIMARY KEY REFERENCES meton_ledger.cash_closure_scopes,
    identity_event uuid NOT NULL UNIQUE CHECK(identity_event<>'00000000-0000-0000-0000-000000000000'),
    identity_fact jsonb NOT NULL,inventory jsonb NOT NULL,
    responsible_ref text NOT NULL CHECK(responsible_ref~'^[a-z0-9][a-z0-9._/-]{0,127}$'),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
DO $protect$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['cash_closure_aftercare_policies','cash_closure_final_facts'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',t);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',t);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',t);
    END LOOP;
END $protect$;

ALTER FUNCTION meton_ledger.require_cash_closure_decision(jsonb,meton_ledger.cash_closure_scopes,jsonb,text,timestamptz)
    RENAME TO require_cash_closure_decision_v343;
/** 已关闭必须带原最终事件与裁决版本；不能把 closing 投影或旧撤回当成关闭后的执行权。 */
CREATE FUNCTION meton_ledger.require_cash_closure_decision(o jsonb,s meton_ledger.cash_closure_scopes,fact jsonb,decision text,until_at timestamptz)
RETURNS void LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF decision IS DISTINCT FROM 'closed' THEN
        PERFORM meton_ledger.require_cash_closure_decision_v343(o,s,fact,decision,until_at);RETURN;
    END IF;
    IF until_at IS NULL OR until_at<=clock_timestamp() OR until_at>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'original closure identity window expired' USING ERRCODE='55000'; END IF;
    IF (jsonb_typeof(fact)='object' AND fact ?& ARRAY['closure','registration','decision','lifecycle','securityVersion',
        'recoveryVersion','lastStopVersion','identityEvent','revision','closedAt','giftEligibility'] AND
        fact-ARRAY['closure','registration','decision','lifecycle','securityVersion','recoveryVersion','lastStopVersion',
            'identityEvent','revision','closedAt','giftEligibility']='{}'::jsonb AND
        (fact->>'closure')::uuid=s.closure_id AND (fact->>'registration')::uuid=s.registration AND
        fact->>'decision'='closed' AND fact->>'lifecycle'='closed' AND
        (fact->>'securityVersion')::bigint=(s.identity_fact->>'securityVersion')::bigint+1 AND
        (fact->>'recoveryVersion')::bigint=(s.identity_fact->>'recoveryVersion')::bigint AND
        (fact->>'lastStopVersion')::bigint=(fact->>'securityVersion')::bigint AND
        (fact->>'identityEvent')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid AND (fact->>'revision')::bigint>=3 AND
        (fact->>'giftEligibility')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid AND
        isfinite((fact->>'closedAt')::timestamptz) AND (fact->>'closedAt')::timestamptz>=s.bound_at AND
        (fact->>'closedAt')::timestamptz<=clock_timestamp()) IS NOT TRUE THEN
        RAISE EXCEPTION 'committed original final closure required' USING ERRCODE='42501'; END IF;
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_account_facts f JOIN public.users u ON u.id=(o->>'remote_user')::bigint WHERE
        (f.source_marker,f.registration,f.user_id,f.account_id,f.creation,f.projection_epoch)=
            ((o->>'source_marker')::uuid,s.registration,(o->>'user')::uuid,(o->>'account')::uuid,(o->>'creation')::uuid,(o->>'epoch')::bigint)
        AND (f.lifecycle,f.security_version,f.recovery_version,f.last_stop_version)=
            ('closed',(fact->>'securityVersion')::bigint,(fact->>'recoveryVersion')::bigint,(fact->>'lastStopVersion')::bigint)
        AND f.preparing_closure IS NULL AND u.role='user' AND u.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'current original closed account required' USING ERRCODE='42501'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.registration_grants g WHERE g.source_marker=(o->>'source_marker')::uuid AND
        g.eligibility IS DISTINCT FROM (fact->>'giftEligibility')::uuid) OR EXISTS(
        SELECT FROM meton_ledger.cash_closure_snapshots snap,jsonb_array_elements(snap.items) item WHERE snap.snapshot_id=s.snapshot_id AND
            item->>'kind'='registration' AND item#>>'{value,eligibility}' IS NOT NULL AND
            (item#>>'{value,eligibility}')::uuid IS DISTINCT FROM (fact->>'giftEligibility')::uuid) THEN
        RAISE EXCEPTION 'original gift eligibility differs' USING ERRCODE='42501'; END IF;
END $$;

/** 原始清单保留审计，实时清单继续显示迟到款项；两者都不是已结清证明或第二份余额。 */
CREATE FUNCTION meton_ledger.cash_closure_aftercare_view(s meton_ledger.cash_closure_scopes,f meton_ledger.cash_closure_final_facts)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE current_inventory jsonb;
BEGIN
    IF f.closure_id IS NULL THEN RETURN NULL; END IF;
    current_inventory:=meton_ledger.cash_closure_inventory(s.owner);
    RETURN jsonb_build_object('format',1,'state','aftercare_open','closure',s.closure_id,'registration',s.registration,
        'scopeHash',s.receipt->>'scopeHash','identityEvent',f.identity_event,'identity',f.identity_fact,
        'recordedAt',f.recorded_at,'responsible',f.responsible_ref,'rights','retained_original_sources',
        'funds','not_declared_settled','opening',f.inventory-'items','current',current_inventory-'items');
END $$;

/** 身份已关闭后可靠接续原事实。应答丢失重读原记录；再次调用不换负责人、原范围或最终事件。 */
CREATE FUNCTION meton_ledger.record_cash_closure_final(o jsonb,p_closure uuid,p_registration uuid,p_scope text,fact jsonb,until_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s meton_ledger.cash_closure_scopes;f meton_ledger.cash_closure_final_facts;custodian text;observed jsonb;
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'admit');
    PERFORM meton_ledger.require_cash_writer(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    SELECT * INTO s FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration
        AND receipt->>'scopeHash'=p_scope;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((o->>'source_marker')::uuid));
    PERFORM pg_advisory_xact_lock(hashtextextended('cash-closure-refunds/'||p_closure::text,0));
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closed',until_at);
    IF EXISTS(SELECT FROM meton_ledger.cash_closure_refund_controls WHERE closure_id=p_closure AND stopped_at IS NOT NULL) THEN
        RAISE EXCEPTION 'withdrawn closure cannot enter aftercare' USING ERRCODE='42501'; END IF;
    SELECT * INTO f FROM meton_ledger.cash_closure_final_facts WHERE closure_id=p_closure;
    IF FOUND THEN
        IF f.identity_fact IS DISTINCT FROM fact THEN RAISE EXCEPTION 'original final closure differs' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.cash_closure_aftercare_view(s,f);
    END IF;
    SELECT responsible_ref INTO custodian FROM meton_ledger.cash_closure_aftercare_policies WHERE
        (deployment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    IF custodian IS NULL THEN RAISE EXCEPTION 'original aftercare responsibility unavailable' USING ERRCODE='55000'; END IF;
    observed:=meton_ledger.cash_closure_inventory(o);
    -- 清单可能包含未决 H、尾差和过窗款。关闭不修改它们，原范围以外的事项也只保留核对而不自动扩权。
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closed',until_at);
    INSERT INTO meton_ledger.cash_closure_final_facts(closure_id,identity_event,identity_fact,inventory,responsible_ref)
        VALUES(p_closure,(fact->>'identityEvent')::uuid,fact,observed,custodian) RETURNING * INTO f;
    RETURN meton_ledger.cash_closure_aftercare_view(s,f);
END $$;

CREATE FUNCTION meton_ledger.read_cash_closure_aftercare(o jsonb,p_closure uuid,p_registration uuid,p_scope text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s meton_ledger.cash_closure_scopes;f meton_ledger.cash_closure_final_facts;
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'read');
    SELECT * INTO s FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration
        AND receipt->>'scopeHash'=p_scope;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    SELECT * INTO f FROM meton_ledger.cash_closure_final_facts WHERE closure_id=p_closure;
    RETURN meton_ledger.cash_closure_aftercare_view(s,f);
END $$;

/** 关闭后的新增补退仍使用原占用算法，另须存在同一最终事件的售后交接。 */
CREATE FUNCTION meton_ledger.require_cash_closure_admission(o jsonb,s meton_ledger.cash_closure_scopes,fact jsonb,until_at timestamptz)
RETURNS void LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF fact->>'decision'='closed' THEN
        PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closed',until_at);
        IF NOT EXISTS(SELECT FROM meton_ledger.cash_closure_final_facts f WHERE f.closure_id=s.closure_id AND f.identity_fact=fact) THEN
            RAISE EXCEPTION 'original aftercare handoff required' USING ERRCODE='42501'; END IF;
    ELSE
        PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closing',until_at);
    END IF;
END $$;
DO $reuse$
DECLARE body text:=pg_get_functiondef('meton_ledger.admit_cash_closure_refund(jsonb,uuid,uuid,text,jsonb,uuid,bigint,uuid,uuid,text,timestamptz)'::regprocedure);
    old_gate text:='meton_ledger.require_cash_closure_decision(o,s,fact,''closing'',until_at)';
    stop_body text:=pg_get_functiondef('meton_ledger.stop_cash_closure_refunds(jsonb,uuid,uuid,text,jsonb,timestamptz)'::regprocedure);
    stop_anchor text:='    SELECT * INTO c FROM meton_ledger.cash_closure_refund_controls WHERE closure_id=p_closure FOR UPDATE;';
BEGIN
    IF cardinality(string_to_array(body,old_gate))<>4 OR cardinality(string_to_array(stop_body,stop_anchor))<>2 THEN
        RAISE EXCEPTION 'original closure admission or stop changed'; END IF;
    EXECUTE replace(body,old_gate,'meton_ledger.require_cash_closure_admission(o,s,fact,until_at)');
    -- 最终关闭和停止共用原范围锁。迟到旧撤回不能把已交接售后范围改成停止。
    EXECUTE replace(stop_body,stop_anchor,
        '    IF EXISTS(SELECT FROM meton_ledger.cash_closure_final_facts WHERE closure_id=p_closure) THEN'||E'\n'||
        '        RAISE EXCEPTION ''final closure cannot be withdrawn'' USING ERRCODE=''42501''; END IF;'||E'\n'||stop_anchor);
END $reuse$;
REVOKE ALL ON FUNCTION meton_ledger.require_cash_closure_decision_v343(jsonb,meton_ledger.cash_closure_scopes,jsonb,text,timestamptz),
    meton_ledger.require_cash_closure_decision(jsonb,meton_ledger.cash_closure_scopes,jsonb,text,timestamptz),
    meton_ledger.cash_closure_aftercare_view(meton_ledger.cash_closure_scopes,meton_ledger.cash_closure_final_facts),
    meton_ledger.record_cash_closure_final(jsonb,uuid,uuid,text,jsonb,timestamptz),
    meton_ledger.read_cash_closure_aftercare(jsonb,uuid,uuid,text),
    meton_ledger.require_cash_closure_admission(jsonb,meton_ledger.cash_closure_scopes,jsonb,timestamptz) FROM PUBLIC;
