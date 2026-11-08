-- 切换期间封住原写口。历史已执行的返还原样保留，待执行的旧批准须先按原流程核清。
LOCK TABLE meton_ledger.text_correction_decisions,meton_ledger.text_corrections IN SHARE ROW EXCLUSIVE MODE;
DO $cutover$
BEGIN
    IF EXISTS(SELECT FROM meton_ledger.text_correction_decisions d LEFT JOIN meton_ledger.text_corrections x USING(decision)
              WHERE x.decision IS NULL OR NOT meton_ledger.correction_has_journal(d.decision,x.journal)) THEN
        RAISE EXCEPTION 'unresolved historical correction at cutover' USING ERRCODE='55000';
    END IF;
END $cutover$;

CREATE TABLE meton_ledger.operations_correction_cases (
    case_id uuid PRIMARY KEY CHECK(case_id<>'00000000-0000-0000-0000-000000000000'),
    request_id uuid NOT NULL, item_id uuid NOT NULL, basis uuid NOT NULL REFERENCES meton_ledger.text_postings(report_event),
    UNIQUE(request_id,item_id,basis),
    FOREIGN KEY(request_id,item_id,basis) REFERENCES meton_ledger.text_fee_reports(request_id,item_id,event_id)
);
CREATE TABLE meton_ledger.operations_correction_steps (
    decision uuid PRIMARY KEY REFERENCES meton_ledger.text_correction_decisions,
    case_id uuid NOT NULL REFERENCES meton_ledger.operations_correction_cases,
    attempt_id uuid NOT NULL UNIQUE CHECK(attempt_id<>'00000000-0000-0000-0000-000000000000'),
    ruling_version integer NOT NULL CHECK(ruling_version>0), epoch bigint NOT NULL CHECK(epoch>0),
    UNIQUE(case_id,ruling_version)
);
CREATE TABLE meton_ledger.operations_correction_approvals (
    decision uuid NOT NULL REFERENCES meton_ledger.operations_correction_steps,
    generation integer NOT NULL CHECK(generation>0), digest text NOT NULL UNIQUE CHECK(digest ~ '^[a-f0-9]{64}$'),
    previous_digest text, reviewer name NOT NULL, valid_until timestamptz NOT NULL, permit_until timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(decision,generation), UNIQUE(decision,generation,digest),
    CHECK((generation=1 AND previous_digest IS NULL) OR (generation>1 AND previous_digest IS NOT NULL AND previous_digest ~ '^[a-f0-9]{64}$')),
    CHECK(isfinite(valid_until) AND isfinite(permit_until) AND recorded_at<valid_until AND recorded_at<permit_until)
);
CREATE TABLE meton_ledger.operations_correction_effects (
    decision uuid PRIMARY KEY REFERENCES meton_ledger.text_corrections,
    generation integer NOT NULL, digest text NOT NULL, executor name NOT NULL,
    journal uuid NOT NULL UNIQUE REFERENCES meton_ledger.events(event_id),
    permit_until timestamptz NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(decision,generation,digest) REFERENCES meton_ledger.operations_correction_approvals(decision,generation,digest),
    CHECK(isfinite(permit_until) AND recorded_at<permit_until)
);
DO $immutable$
DECLARE relation text;
BEGIN
    FOREACH relation IN ARRAY ARRAY['operations_correction_cases','operations_correction_steps','operations_correction_approvals','operations_correction_effects'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',relation);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',relation);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',relation);
    END LOOP;
END $immutable$;

CREATE FUNCTION meton_ledger.check_correction_deadline(p_permit timestamptz,p_valid timestamptz)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE checked_at timestamptz:=clock_timestamp();
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR p_permit IS NULL OR p_valid IS NULL OR
       NOT isfinite(p_permit) OR NOT isfinite(p_valid) OR p_permit>checked_at+interval '30 seconds' OR
       p_valid>checked_at+interval '365 days' THEN
        RAISE EXCEPTION 'invalid correction permit' USING ERRCODE='22023';
    END IF;
    IF least(p_permit,p_valid)<=checked_at THEN
        RAISE EXCEPTION 'expired correction authority' USING ERRCODE='55000';
    END IF;
END $$;

-- 原函数保持唯一资金写入权。即使还有角色持有旧函数的 EXECUTE，缺少本事务的受控依据也不能提交。
CREATE FUNCTION meton_ledger.check_operations_correction_evidence()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE granted_approval meton_ledger.operations_correction_approvals%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME='text_correction_decisions' THEN
        IF NOT EXISTS(SELECT FROM meton_ledger.operations_correction_steps s JOIN meton_ledger.operations_correction_cases c USING(case_id)
            JOIN meton_ledger.operations_correction_approvals a ON a.decision=s.decision AND a.generation=1
            WHERE s.decision=NEW.decision AND (c.request_id,c.item_id,c.basis,s.ruling_version)=(NEW.request_id,NEW.item_id,NEW.basis,NEW.version)) THEN
            RAISE EXCEPTION 'original correction requires managed approval' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='text_corrections' THEN
        IF NOT EXISTS(SELECT FROM meton_ledger.operations_correction_effects e WHERE (e.decision,e.journal)=(NEW.decision,NEW.journal)) THEN
            RAISE EXCEPTION 'original correction requires managed execution' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='operations_correction_approvals' THEN
        IF NEW.reviewer<>session_user OR (NEW.generation>1 AND NOT EXISTS(SELECT FROM meton_ledger.operations_correction_approvals a
            WHERE (a.decision,a.generation,a.digest)=(NEW.decision,NEW.generation-1,NEW.previous_digest) AND a.valid_until<=NEW.recorded_at)) THEN
            RAISE EXCEPTION 'invalid correction approval lineage' USING ERRCODE='23514';
        END IF;
        PERFORM meton_ledger.check_correction_deadline(NEW.permit_until,NEW.valid_until);
    ELSE
        SELECT * INTO STRICT granted_approval FROM meton_ledger.operations_correction_approvals
            WHERE (decision,generation,digest)=(NEW.decision,NEW.generation,NEW.digest);
        IF NEW.executor<>session_user OR NEW.executor=granted_approval.reviewer OR
            EXISTS(SELECT FROM meton_ledger.operations_correction_approvals WHERE decision=NEW.decision AND generation>NEW.generation) OR
            NOT EXISTS(SELECT FROM meton_ledger.text_corrections WHERE decision=NEW.decision AND journal=NEW.journal) OR
            NOT meton_ledger.correction_has_journal(NEW.decision,NEW.journal) THEN
            RAISE EXCEPTION 'invalid original correction effect' USING ERRCODE='23514';
        END IF;
        PERFORM meton_ledger.check_correction_deadline(NEW.permit_until,granted_approval.valid_until);
    END IF;
    RETURN NULL;
END $$;
DO $evidence$
DECLARE relation text;
BEGIN
    FOREACH relation IN ARRAY ARRAY['text_correction_decisions','text_corrections','operations_correction_approvals','operations_correction_effects'] LOOP
        EXECUTE format('CREATE CONSTRAINT TRIGGER operations_evidence AFTER INSERT ON meton_ledger.%I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_operations_correction_evidence()',relation);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER operations_evidence',relation);
    END LOOP;
END $evidence$;

CREATE FUNCTION meton_ledger.find_operations_correction(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_decision uuid,p_case uuid,p_attempt uuid,p_version integer,p_generation integer,p_digest text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('format_version',1,'case_id',c.case_id,'attempt_id',s.attempt_id,'epoch',s.epoch,
        'generation',a.generation,'approval_digest',a.digest,'valid_until',a.valid_until,'approval',original.ruling,
        'state',CASE WHEN e.generation=a.generation THEN 'applied' WHEN head.generation>a.generation THEN 'superseded' ELSE 'approved' END,
        'journal',CASE WHEN e.generation=a.generation THEN e.journal END)
    FROM meton_ledger.operations_correction_cases c JOIN meton_ledger.operations_correction_steps s USING(case_id)
    JOIN meton_ledger.operations_correction_approvals a USING(decision)
    CROSS JOIN LATERAL (SELECT max(h.generation) AS generation FROM meton_ledger.operations_correction_approvals h WHERE h.decision=s.decision) head
    CROSS JOIN LATERAL (SELECT meton_ledger.find_text_decision(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,
        p_request,p_item,p_basis,p_decision) AS ruling) original
    LEFT JOIN meton_ledger.text_corrections x ON x.decision=s.decision LEFT JOIN meton_ledger.operations_correction_effects e ON e.decision=s.decision
    WHERE (c.request_id,c.item_id,c.basis,c.case_id,s.decision,s.attempt_id,s.ruling_version,a.generation,a.digest)=
          (p_request,p_item,p_basis,p_case,p_decision,p_attempt,p_version,p_generation,p_digest) AND original.ruling IS NOT NULL
      AND (x.decision IS NULL AND e.decision IS NULL OR e.generation=head.generation AND x.journal=e.journal AND meton_ledger.correction_has_journal(s.decision,e.journal))
$$;

CREATE FUNCTION meton_ledger.approve_operations_correction(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_decision uuid,p_case uuid,p_attempt uuid,p_version integer,p_generation integer,p_digest text,
    p_previous text,p_final boolean,p_sources jsonb,p_valid timestamptz,p_permit timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    selected jsonb; original jsonb; step meton_ledger.operations_correction_steps%ROWTYPE;
    latest meton_ledger.operations_correction_approvals%ROWTYPE; known jsonb;
BEGIN
    IF num_nulls(p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest,p_final)>0 OR
       '00000000-0000-0000-0000-000000000000'::uuid IN (p_item,p_basis,p_decision,p_case,p_attempt) OR
       p_version<1 OR p_generation<1 OR p_digest !~ '^[a-f0-9]{64}$' OR
       (p_previous IS NULL)<>(p_generation=1) OR (p_previous IS NOT NULL AND p_previous !~ '^[a-f0-9]{64}$') OR
       jsonb_typeof(p_sources) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'invalid correction approval' USING ERRCODE='22023';
    END IF;
    IF jsonb_array_length(p_sources) NOT BETWEEN 1 AND 64 THEN RAISE EXCEPTION 'invalid correction source count' USING ERRCODE='22023'; END IF;
    selected:=meton_ledger.correction_sources(p_sources);
    PERFORM meton_ledger.check_correction_deadline(p_permit,p_valid);
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    PERFORM meton_ledger.check_correction_deadline(p_permit,p_valid);
    SELECT * INTO step FROM meton_ledger.operations_correction_steps WHERE decision=p_decision;
    IF FOUND THEN
        IF (step.case_id,step.attempt_id,step.ruling_version,step.epoch) IS DISTINCT FROM (p_case,p_attempt,p_version,p_epoch) THEN
            RAISE EXCEPTION 'different original correction step' USING ERRCODE='23505';
        END IF;
        original:=meton_ledger.find_text_decision(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis,p_decision);
        IF original IS NULL OR (original->'sources',(original->>'final')::boolean) IS DISTINCT FROM (selected,p_final) THEN
            RAISE EXCEPTION 'different original correction selection' USING ERRCODE='23505';
        END IF;
        SELECT * INTO latest FROM meton_ledger.operations_correction_approvals WHERE decision=p_decision ORDER BY generation DESC LIMIT 1;
        known:=meton_ledger.find_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
            p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest);
        IF known IS NOT NULL THEN
            IF NOT EXISTS(SELECT FROM meton_ledger.operations_correction_approvals WHERE decision=p_decision AND generation=p_generation
                AND valid_until=p_valid AND previous_digest IS NOT DISTINCT FROM p_previous AND reviewer=session_user) THEN
                RAISE EXCEPTION 'different approval intent' USING ERRCODE='23505';
            END IF;
            RETURN known;
        END IF;
        IF latest.decision IS NULL OR p_generation::bigint<>latest.generation::bigint+1 OR p_previous IS DISTINCT FROM latest.digest
            OR latest.valid_until>clock_timestamp() OR EXISTS(SELECT FROM meton_ledger.text_corrections WHERE decision=p_decision) THEN
            RAISE EXCEPTION 'expired unapplied original approval required' USING ERRCODE='55000';
        END IF;
    ELSE
        IF p_generation<>1 OR EXISTS(SELECT FROM meton_ledger.text_correction_decisions WHERE decision=p_decision) THEN
            RAISE EXCEPTION 'legacy or different original ruling' USING ERRCODE='23505';
        END IF;
        -- 281 只能在尚无裁决时补齐差额。这里必须取同一费项已覆盖的最新结算。
        IF NOT EXISTS(SELECT FROM meton_ledger.latest_text_fees WHERE (request_id,item_id,event_id)=(p_request,p_item,p_basis) AND uncovered=0) THEN
            RAISE EXCEPTION 'fully funded current settlement required' USING ERRCODE='55000';
        END IF;
        INSERT INTO meton_ledger.operations_correction_cases(case_id,request_id,item_id,basis) VALUES(p_case,p_request,p_item,p_basis) ON CONFLICT DO NOTHING;
        IF NOT EXISTS(SELECT FROM meton_ledger.operations_correction_cases WHERE (case_id,request_id,item_id,basis)=(p_case,p_request,p_item,p_basis)) THEN
            RAISE EXCEPTION 'different original correction case' USING ERRCODE='23505';
        END IF;
        PERFORM meton_ledger.approve_text_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
            p_item,p_basis,p_decision,p_version,p_final,selected);
        INSERT INTO meton_ledger.operations_correction_steps(decision,case_id,attempt_id,ruling_version,epoch)
            VALUES(p_decision,p_case,p_attempt,p_version,p_epoch);
    END IF;
    PERFORM meton_ledger.check_correction_deadline(p_permit,p_valid);
    INSERT INTO meton_ledger.operations_correction_approvals(decision,generation,digest,previous_digest,reviewer,valid_until,permit_until)
        VALUES(p_decision,p_generation,p_digest,p_previous,session_user,p_valid,p_permit);
    RETURN meton_ledger.find_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest);
END $$;

CREATE FUNCTION meton_ledger.apply_operations_correction(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_decision uuid,p_case uuid,p_attempt uuid,p_version integer,p_generation integer,p_digest text,p_permit timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.operations_correction_approvals%ROWTYPE; known jsonb; receipt jsonb;
BEGIN
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    known:=meton_ledger.find_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest);
    IF known IS NULL OR known->>'state'='superseded' OR (known->>'epoch')::bigint IS DISTINCT FROM p_epoch THEN
        RAISE EXCEPTION 'current bound correction required' USING ERRCODE='55000';
    END IF;
    SELECT * INTO STRICT a FROM meton_ledger.operations_correction_approvals WHERE decision=p_decision AND generation=p_generation;
    IF a.reviewer=session_user THEN RAISE EXCEPTION 'independent correction executor required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.check_correction_deadline(p_permit,a.valid_until);
    IF known->>'state'='applied' THEN RETURN known; END IF;
    receipt:=meton_ledger.apply_text_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_version);
    PERFORM meton_ledger.check_correction_deadline(p_permit,a.valid_until);
    INSERT INTO meton_ledger.operations_correction_effects(decision,generation,digest,executor,journal,permit_until)
        VALUES(p_decision,p_generation,p_digest,session_user,(receipt->>'journal')::uuid,p_permit);
    RETURN meton_ledger.find_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.check_correction_deadline(timestamptz,timestamptz),meton_ledger.check_operations_correction_evidence(),
    meton_ledger.find_operations_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,integer,integer,text),
    meton_ledger.approve_operations_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,integer,integer,text,text,boolean,jsonb,timestamptz,timestamptz),
    meton_ledger.apply_operations_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,integer,integer,text,timestamptz)
    FROM PUBLIC;
