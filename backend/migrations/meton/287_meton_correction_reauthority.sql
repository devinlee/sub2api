-- 只补批准的授权元数据。原裁决、批准摘要、人员、期限和资金事实保持。
LOCK TABLE meton_ledger.operations_correction_approvals,meton_ledger.operations_correction_steps,
    meton_ledger.operations_correction_cases,meton_ledger.operations_correction_effects IN SHARE ROW EXCLUSIVE MODE;
ALTER TABLE meton_ledger.operations_correction_approvals ADD COLUMN authority_epoch bigint;
-- 仅在所有者迁移事务及表锁内补新列；失败回滚同时恢复原触发器，运行角色不能走此路径。
ALTER TABLE meton_ledger.operations_correction_approvals DISABLE TRIGGER immutable_fact;
UPDATE meton_ledger.operations_correction_approvals a SET authority_epoch=s.epoch
    FROM meton_ledger.operations_correction_steps s WHERE s.decision=a.decision;
ALTER TABLE meton_ledger.operations_correction_approvals ENABLE ALWAYS TRIGGER immutable_fact;
ALTER TABLE meton_ledger.operations_correction_approvals ALTER COLUMN authority_epoch SET NOT NULL,
    ADD CHECK(authority_epoch>0);

-- 证明原步骤／上一批准确实位于本次原恢复链中；数值落在区间里本身不是证明。
CREATE FUNCTION meton_ledger.correction_epoch_on_chain(p_request uuid,p_previous bigint,p_current bigint)
RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    WITH RECURSIVE original AS (
        SELECT r.epoch_at_accept,m.* FROM meton_ledger.text_requests r
        JOIN public.meton_managed_creations m ON m.source_marker=r.source_marker
        WHERE r.request_id=p_request AND r.epoch_at_accept<=p_previous AND p_previous<=p_current AND p_current<=m.epoch
    ), hops(epoch) AS (
        SELECT epoch_at_accept FROM original
        UNION ALL
        SELECT r.next_epoch FROM hops h JOIN public.meton_recovery_successions r ON r.previous_epoch=h.epoch
        JOIN original o ON (r.environment,r.source,r.meton_user,r.account,r.operation,r.dispatch,r.remote_user,r.source_marker)=
            (o.environment,o.source,o.meton_user,o.account,o.operation,o.dispatch,o.remote_user,o.source_marker)
        WHERE r.next_epoch<=p_current AND r.next_epoch>h.epoch
    ) SELECT EXISTS(SELECT FROM hops WHERE epoch=p_previous) AND EXISTS(SELECT FROM hops WHERE epoch=p_current)
$$;
REVOKE ALL ON FUNCTION meton_ledger.correction_epoch_on_chain(uuid,bigint,bigint) FROM PUBLIC;

CREATE OR REPLACE FUNCTION meton_ledger.check_operations_correction_evidence()
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
        IF NEW.reviewer<>session_user OR NOT EXISTS(SELECT FROM meton_ledger.operations_correction_steps s
            JOIN meton_ledger.operations_correction_cases c USING(case_id) WHERE s.decision=NEW.decision AND
                meton_ledger.correction_epoch_on_chain(c.request_id,s.epoch,NEW.authority_epoch)) OR
            (NEW.generation>1 AND NOT EXISTS(SELECT FROM meton_ledger.operations_correction_approvals a
                JOIN meton_ledger.operations_correction_steps s USING(decision) JOIN meton_ledger.operations_correction_cases c USING(case_id)
                WHERE (a.decision,a.generation,a.digest)=(NEW.decision,NEW.generation-1,NEW.previous_digest) AND
                    meton_ledger.correction_epoch_on_chain(c.request_id,a.authority_epoch,NEW.authority_epoch) AND
                    (a.valid_until<=NEW.recorded_at OR a.authority_epoch<NEW.authority_epoch))) THEN
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

CREATE OR REPLACE FUNCTION meton_ledger.find_operations_correction(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_decision uuid,p_case uuid,p_attempt uuid,p_version integer,p_generation integer,p_digest text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('format_version',1,'case_id',c.case_id,'attempt_id',s.attempt_id,'epoch',a.authority_epoch,
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

CREATE OR REPLACE FUNCTION meton_ledger.approve_operations_correction(
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
        IF (step.case_id,step.attempt_id,step.ruling_version) IS DISTINCT FROM (p_case,p_attempt,p_version) OR
            NOT meton_ledger.correction_epoch_on_chain(p_request,step.epoch,p_epoch) THEN
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
            OR NOT meton_ledger.correction_epoch_on_chain(p_request,latest.authority_epoch,p_epoch) OR
            (latest.authority_epoch=p_epoch AND latest.valid_until>clock_timestamp()) OR
            EXISTS(SELECT FROM meton_ledger.text_corrections WHERE decision=p_decision) THEN
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
    INSERT INTO meton_ledger.operations_correction_approvals(decision,generation,digest,previous_digest,reviewer,valid_until,permit_until,authority_epoch)
        VALUES(p_decision,p_generation,p_digest,p_previous,session_user,p_valid,p_permit,p_epoch);
    RETURN meton_ledger.find_operations_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_decision,p_case,p_attempt,p_version,p_generation,p_digest);
END $$;
