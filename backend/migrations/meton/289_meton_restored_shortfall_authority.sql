-- 原 281 分配／扣减算法原样放到私有函数；普通入口不取得跨恢复写权。
CREATE FUNCTION meton_ledger.cover_text_shortfall_core(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_item uuid,p_basis uuid,p_command uuid,p_case uuid,p_attempt uuid,p_approval text,p_until timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; prior meton_ledger.latest_text_fees%ROWTYPE;
    old meton_ledger.text_shortfall_resolutions%ROWTYPE; original_event uuid; observation jsonb;
    available numeric(20,8); left_to_apply numeric(20,8); part numeric(20,8); lot record; pos integer;
    event uuid; journal uuid; seq bigint; native numeric(20,8);
BEGIN
    -- 仍用原账号锁和当前写入栅栏，不借用已撤销的用户 Key；恢复换代不能改写原受理代次。
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF num_nulls(p_item,p_basis,p_command,p_case,p_attempt,p_approval,p_until)>0 OR p_item<>p_request OR
        '00000000-0000-0000-0000-000000000000'::uuid IN (p_item,p_basis,p_command,p_case,p_attempt) OR
        p_approval !~ '^[a-f0-9]{64}$' OR p_until<=clock_timestamp() OR p_until>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'invalid shortfall authority' USING ERRCODE='22023'; END IF;
    SELECT * INTO old FROM meton_ledger.text_shortfall_resolutions WHERE command_id=p_command;
    IF FOUND THEN
        IF (old.request_id,old.item_id,old.basis_event,old.case_id,old.attempt_id,old.approval_digest)
            IS DISTINCT FROM (p_request,p_item,p_basis,p_case,p_attempt,p_approval) THEN
            RAISE EXCEPTION 'different original shortfall command' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.find_text_shortfall(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command);
    END IF;
    SELECT * INTO prior FROM meton_ledger.latest_text_fees WHERE request_id=p_request AND item_id=p_item;
    IF NOT FOUND OR prior.event_id<>p_basis OR prior.uncovered<=0 OR prior.revision=2147483647 OR
        NOT EXISTS(SELECT FROM meton_ledger.text_fee_endings WHERE request_id=p_request) OR
        EXISTS(SELECT FROM meton_ledger.text_correction_decisions WHERE request_id=p_request AND item_id=p_item) THEN
        RAISE EXCEPTION 'current undisputed shortfall required' USING ERRCODE='55000'; END IF;
    SELECT coalesce(r.event_id,c.event_id),coalesce(p.observation,c.observation) INTO original_event,observation
        FROM meton_ledger.text_completions c LEFT JOIN meton_ledger.text_result_resolutions r USING(request_id)
        LEFT JOIN meton_ledger.text_result_proofs p ON p.evidence_id=r.evidence_id WHERE c.request_id=p_request;
    IF original_event IS DISTINCT FROM p_basis OR observation->>'execution' NOT IN ('completed','failed')
        OR (observation->>'fee_ready')::boolean IS NOT TRUE
        OR EXISTS(SELECT FROM meton_ledger.text_result_proofs a JOIN meton_ledger.text_result_proofs b USING(request_id)
            WHERE a.request_id=p_request AND (a.observation-'body_sha256') IS DISTINCT FROM (b.observation-'body_sha256')) THEN
        RAISE EXCEPTION 'known original execution required' USING ERRCODE='55000'; END IF;
    -- 无效果后的下一步只能归于原事项和 Attempt，且须有新的审核摘要；不能换案逃过原拒绝回执。
    IF EXISTS(SELECT FROM meton_ledger.text_shortfall_resolutions s WHERE s.basis_event=p_basis AND
        (s.case_id<>p_case OR s.attempt_id<>p_attempt OR s.approval_digest=p_approval)) THEN
        RAISE EXCEPTION 'original case and renewed approval required' USING ERRCODE='23505'; END IF;
    SELECT coalesce(sum(l.remaining-l.held-l.refund_held),0) INTO available
        FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=p_marker;
    IF available<prior.uncovered THEN
        INSERT INTO meton_ledger.text_shortfall_resolutions(command_id,request_id,item_id,basis_event,case_id,attempt_id,approval_digest,
            state,missing,available_before,event_id,executor)
        VALUES(p_command,p_request,p_item,p_basis,p_case,p_attempt,p_approval,'funds_unavailable',prior.uncovered,available,NULL,session_user);
        RETURN meton_ledger.find_text_shortfall(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command);
    END IF;
    event:=gen_random_uuid();journal:=gen_random_uuid();left_to_apply:=prior.uncovered;
    INSERT INTO meton_ledger.text_fee_reports(event_id,request_id,item_id,revision,state,amount,previous_event)
        VALUES(event,p_request,p_item,prior.revision+1,'revised',prior.amount,p_basis);
    INSERT INTO meton_ledger.text_supplements VALUES(p_request,'fee',event,prior.uncovered,true);
    SELECT coalesce(max(ordinal),0) INTO pos FROM meton_ledger.text_all_slices WHERE request_id=p_request;
    -- 这里只覆盖原费用的差额；同事务内从当前空闲来源追加分配并消费，不碰其他 H 或 R。
    FOR lot IN SELECT l.credit_event,l.remaining-l.held-l.refund_held AS free FROM meton_ledger.lots l
        JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=p_marker AND l.remaining>l.held+l.refund_held
        ORDER BY (e.kind='grant') DESC,e.sequence FOR UPDATE OF l LOOP
        part:=least(left_to_apply,lot.free);pos:=pos+1;
        INSERT INTO meton_ledger.text_supplement_splits VALUES(p_request,'fee',event,pos,lot.credit_event,part);
        -- 分配与消费同时记入原分配账；净 H 不变，已用额度由原正向消费流水解释。
        UPDATE meton_ledger.lots SET remaining=remaining-part WHERE credit_event=lot.credit_event;
        INSERT INTO meton_ledger.text_spend_splits VALUES(event,p_request,pos,lot.credit_event,part,part);
        left_to_apply:=left_to_apply-part;
        EXIT WHEN left_to_apply=0;
    END LOOP;
    IF left_to_apply<>0 THEN RAISE EXCEPTION 'source availability changed' USING ERRCODE='40001'; END IF;
    INSERT INTO meton_ledger.text_postings VALUES(event,prior.amount,0,prior.uncovered,journal);
    UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=p_marker RETURNING last_sequence INTO STRICT seq;
    SELECT u.balance INTO STRICT native FROM public.users u JOIN public.meton_managed_creations m ON m.remote_user=u.id WHERE m.source_marker=p_marker;
    IF native-prior.uncovered IS DISTINCT FROM (SELECT sum(l.remaining) FROM meton_ledger.lots l
        JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=p_marker) THEN
        RAISE EXCEPTION 'shortfall source total mismatch' USING ERRCODE='23514'; END IF;
    INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
        VALUES(journal,p_env,p_source,p_marker,event,'text_revision',event,seq,-prior.uncovered,native,native-prior.uncovered);
    INSERT INTO meton_ledger.text_shortfall_resolutions(command_id,request_id,item_id,basis_event,case_id,attempt_id,approval_digest,
        state,missing,available_before,event_id,executor)
    VALUES(p_command,p_request,p_item,p_basis,p_case,p_attempt,p_approval,'covered',prior.uncovered,available,event,session_user);
    RETURN meton_ledger.find_text_shortfall(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.cover_text_shortfall_core(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,timestamptz) FROM PUBLIC;

CREATE OR REPLACE FUNCTION meton_ledger.cover_text_shortfall(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_item uuid,p_basis uuid,p_command uuid,p_case uuid,p_attempt uuid,p_approval text,p_until timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF h.epoch_at_accept<>p_epoch THEN RAISE EXCEPTION 'restored shortfall approval required' USING ERRCODE='55000'; END IF;
    RETURN meton_ledger.cover_text_shortfall_core(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        p_item,p_basis,p_command,p_case,p_attempt,p_approval,p_until);
END $$;

-- 当前恢复批准独立于原子命令和原费用；已有账本与原命令不改写。
CREATE TABLE meton_ledger.restored_shortfall_approvals (
    command_id uuid NOT NULL, generation integer NOT NULL CHECK(generation>0),
    request_id uuid NOT NULL REFERENCES meton_ledger.text_requests, item_id uuid NOT NULL, basis_event uuid NOT NULL,
    case_id uuid NOT NULL, attempt_id uuid NOT NULL, original_digest text NOT NULL CHECK(original_digest ~ '^[a-f0-9]{64}$'),
    original_epoch bigint NOT NULL CHECK(original_epoch>0), authority_epoch bigint NOT NULL CHECK(authority_epoch>=original_epoch),
    review_digest text NOT NULL CHECK(review_digest ~ '^[a-f0-9]{64}$'), previous_digest text,
    reviewer name NOT NULL, valid_until timestamptz NOT NULL, permit_until timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(command_id,generation), UNIQUE(command_id,review_digest),
    FOREIGN KEY(request_id,item_id,basis_event) REFERENCES meton_ledger.text_fee_reports(request_id,item_id,event_id),
    CHECK((generation=1)=(previous_digest IS NULL)),
    CHECK(previous_digest IS NULL OR previous_digest ~ '^[a-f0-9]{64}$'),
    CHECK(review_digest<>original_digest),
    CHECK('00000000-0000-0000-0000-000000000000'::uuid NOT IN(command_id,case_id,attempt_id))
);
CREATE TABLE meton_ledger.restored_shortfall_effects (
    command_id uuid PRIMARY KEY REFERENCES meton_ledger.text_shortfall_resolutions(command_id) DEFERRABLE INITIALLY DEFERRED,
    generation integer NOT NULL, review_digest text NOT NULL, executor name NOT NULL,
    permit_until timestamptz NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(command_id,generation) REFERENCES meton_ledger.restored_shortfall_approvals(command_id,generation)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.restored_shortfall_approvals
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.restored_shortfall_effects
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.restored_shortfall_approvals ENABLE ALWAYS TRIGGER immutable_fact;
ALTER TABLE meton_ledger.restored_shortfall_effects ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.restored_shortfall_approvals,meton_ledger.restored_shortfall_effects FROM PUBLIC;

-- 只检查原已确认差额；金额和来源分配不来自审核请求。
CREATE FUNCTION meton_ledger.require_restored_shortfall_basis(p_request uuid,p_item uuid,p_basis uuid)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE prior meton_ledger.latest_text_fees%ROWTYPE; original_event uuid; observation jsonb;
BEGIN
    SELECT * INTO prior FROM meton_ledger.latest_text_fees WHERE request_id=p_request AND item_id=p_item;
    IF NOT FOUND OR p_item<>p_request OR prior.event_id<>p_basis OR prior.uncovered<=0 OR prior.revision<>1 OR
        NOT EXISTS(SELECT FROM meton_ledger.text_fee_endings WHERE request_id=p_request) OR
        EXISTS(SELECT FROM meton_ledger.text_correction_decisions WHERE request_id=p_request AND item_id=p_item) THEN
        RAISE EXCEPTION 'current undisputed original shortfall required' USING ERRCODE='55000'; END IF;
    SELECT coalesce(r.event_id,c.event_id),coalesce(p.observation,c.observation) INTO original_event,observation
        FROM meton_ledger.text_completions c LEFT JOIN meton_ledger.text_result_resolutions r USING(request_id)
        LEFT JOIN meton_ledger.text_result_proofs p ON p.evidence_id=r.evidence_id WHERE c.request_id=p_request;
    IF original_event IS DISTINCT FROM p_basis OR observation->>'execution' NOT IN ('completed','failed') OR
        (observation->>'fee_ready')::boolean IS NOT TRUE OR
        EXISTS(SELECT FROM meton_ledger.text_result_proofs a JOIN meton_ledger.text_result_proofs b USING(request_id)
            WHERE a.request_id=p_request AND (a.observation-'body_sha256') IS DISTINCT FROM (b.observation-'body_sha256')) THEN
        RAISE EXCEPTION 'known original shortfall execution required' USING ERRCODE='55000'; END IF;
END $$;

-- 读取必须核对原恢复链；查无保持 NULL，不生成新的批准或无效果回执。
CREATE FUNCTION meton_ledger.find_restored_shortfall_approval(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_command uuid,p_generation integer,p_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; a meton_ledger.restored_shortfall_approvals%ROWTYPE;
    effect meton_ledger.restored_shortfall_effects%ROWTYPE; latest integer;
BEGIN
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request THEN RETURN NULL; END IF;
    PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
    SELECT * INTO a FROM meton_ledger.restored_shortfall_approvals
        WHERE (command_id,generation,review_digest,request_id)=(p_command,p_generation,p_digest,p_request);
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF NOT meton_ledger.correction_epoch_on_chain(p_request,a.original_epoch,a.authority_epoch) OR
        NOT meton_ledger.correction_epoch_on_chain(p_request,a.authority_epoch,p_epoch) THEN
        RAISE EXCEPTION 'original shortfall approval chain required' USING ERRCODE='55000'; END IF;
    SELECT * INTO effect FROM meton_ledger.restored_shortfall_effects WHERE command_id=p_command;
    SELECT max(generation) INTO latest FROM meton_ledger.restored_shortfall_approvals WHERE command_id=p_command;
    RETURN jsonb_build_object('version',1,'request_id',a.request_id,'item_id',a.item_id,'basis_event',a.basis_event,
        'command_id',a.command_id,'case_id',a.case_id,'attempt_id',a.attempt_id,'original_digest',a.original_digest,
        'original_epoch',a.original_epoch,'authority_epoch',a.authority_epoch,'generation',a.generation,'review_digest',a.review_digest,
        'previous_digest',a.previous_digest,'valid_until',a.valid_until,
        'state',CASE WHEN effect.generation=a.generation THEN 'resolved' WHEN latest>a.generation THEN 'superseded' ELSE 'approved' END,
        'result',CASE WHEN effect.generation=a.generation THEN
            meton_ledger.find_text_shortfall(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command) END);
END $$;

CREATE FUNCTION meton_ledger.approve_restored_shortfall(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_item uuid,p_basis uuid,p_command uuid,p_case uuid,p_attempt uuid,p_original text,p_original_epoch bigint,
    p_generation integer,p_digest text,p_previous text,p_valid timestamptz,p_permit timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; latest meton_ledger.restored_shortfall_approvals%ROWTYPE;
    selected meton_ledger.restored_shortfall_approvals%ROWTYPE; known jsonb;
BEGIN
    IF num_nulls(p_item,p_basis,p_command,p_case,p_attempt,p_original,p_original_epoch,p_generation,p_digest,p_valid,p_permit)>0 OR
        '00000000-0000-0000-0000-000000000000'::uuid IN(p_item,p_basis,p_command,p_case,p_attempt) OR p_generation<1 OR
        p_original !~ '^[a-f0-9]{64}$' OR p_digest !~ '^[a-f0-9]{64}$' OR p_original=p_digest OR
        (p_generation=1)<>(p_previous IS NULL) OR (p_previous IS NOT NULL AND p_previous !~ '^[a-f0-9]{64}$') THEN
        RAISE EXCEPTION 'invalid restored shortfall approval' USING ERRCODE='22023'; END IF;
    PERFORM meton_ledger.check_correction_deadline(p_permit,p_valid);
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF p_epoch<=h.epoch_at_accept OR NOT meton_ledger.correction_epoch_on_chain(p_request,p_original_epoch,p_epoch) THEN
        RAISE EXCEPTION 'restored original shortfall required' USING ERRCODE='55000'; END IF;
    IF has_function_privilege(session_user,'meton_ledger.cover_text_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,timestamptz)','EXECUTE') OR
        has_function_privilege(session_user,'meton_ledger.cover_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,integer,text,timestamptz)','EXECUTE') THEN
        RAISE EXCEPTION 'shortfall approval and execution must be separate' USING ERRCODE='42501'; END IF;
    SELECT * INTO latest FROM meton_ledger.restored_shortfall_approvals WHERE command_id=p_command ORDER BY generation DESC LIMIT 1;
    IF FOUND THEN
        IF (latest.request_id,latest.item_id,latest.basis_event,latest.case_id,latest.attempt_id,latest.original_digest,latest.original_epoch)
            IS DISTINCT FROM (p_request,p_item,p_basis,p_case,p_attempt,p_original,p_original_epoch) THEN
            RAISE EXCEPTION 'different original shortfall selection' USING ERRCODE='23505'; END IF;
        SELECT * INTO selected FROM meton_ledger.restored_shortfall_approvals WHERE command_id=p_command AND generation=p_generation;
        IF FOUND THEN
            IF (selected.authority_epoch,selected.review_digest,selected.previous_digest,selected.valid_until,selected.reviewer)
                IS DISTINCT FROM (p_epoch,p_digest,p_previous,p_valid,session_user) THEN
                RAISE EXCEPTION 'different shortfall approval intent' USING ERRCODE='23505'; END IF;
            RETURN meton_ledger.find_restored_shortfall_approval(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command,p_generation,p_digest);
        END IF;
        IF p_generation::bigint<>latest.generation::bigint+1 OR p_previous IS DISTINCT FROM latest.review_digest OR
            NOT meton_ledger.correction_epoch_on_chain(p_request,latest.authority_epoch,p_epoch) OR
            (latest.authority_epoch=p_epoch AND latest.valid_until>clock_timestamp()) THEN
            RAISE EXCEPTION 'expired or prior recovery approval required' USING ERRCODE='55000'; END IF;
    ELSIF p_generation<>1 THEN RAISE EXCEPTION 'first shortfall approval required' USING ERRCODE='55000'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.text_shortfall_resolutions WHERE command_id=p_command) OR
        EXISTS(SELECT FROM meton_ledger.restored_shortfall_effects WHERE command_id=p_command) THEN
        RAISE EXCEPTION 'resolved shortfall command is immutable' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.require_restored_shortfall_basis(p_request,p_item,p_basis);
    -- 只有此前原步骤已经明确资金不足才允许另开子步骤；查无或未决批准不能改号逃逸。
    IF EXISTS(SELECT FROM meton_ledger.restored_shortfall_approvals a LEFT JOIN meton_ledger.text_shortfall_resolutions r USING(command_id)
        WHERE a.basis_event=p_basis AND a.command_id<>p_command AND
            (a.case_id<>p_case OR a.attempt_id<>p_attempt OR a.original_digest=p_original OR r.state IS DISTINCT FROM 'funds_unavailable')) OR
       EXISTS(SELECT FROM meton_ledger.text_shortfall_resolutions r WHERE r.basis_event=p_basis AND
            (r.case_id<>p_case OR r.attempt_id<>p_attempt OR r.approval_digest=p_original OR r.state<>'funds_unavailable')) THEN
        RAISE EXCEPTION 'same original case and confirmed no effect required' USING ERRCODE='23505'; END IF;
    PERFORM meton_ledger.check_correction_deadline(p_permit,p_valid);
    INSERT INTO meton_ledger.restored_shortfall_approvals(command_id,generation,request_id,item_id,basis_event,case_id,attempt_id,
        original_digest,original_epoch,authority_epoch,review_digest,previous_digest,reviewer,valid_until,permit_until)
    VALUES(p_command,p_generation,p_request,p_item,p_basis,p_case,p_attempt,p_original,p_original_epoch,p_epoch,p_digest,p_previous,session_user,p_valid,p_permit);
    RETURN meton_ledger.find_restored_shortfall_approval(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command,p_generation,p_digest);
END $$;

CREATE FUNCTION meton_ledger.cover_restored_shortfall(
    p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid,
    p_command uuid,p_generation integer,p_digest text,p_permit timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; a meton_ledger.restored_shortfall_approvals%ROWTYPE;
    effect meton_ledger.restored_shortfall_effects%ROWTYPE; result jsonb;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    SELECT * INTO a FROM meton_ledger.restored_shortfall_approvals
        WHERE (command_id,generation,review_digest,request_id)=(p_command,p_generation,p_digest,p_request);
    IF NOT FOUND OR p_epoch<=h.epoch_at_accept OR a.authority_epoch<>p_epoch OR
        NOT meton_ledger.correction_epoch_on_chain(p_request,a.original_epoch,p_epoch) OR
        EXISTS(SELECT FROM meton_ledger.restored_shortfall_approvals WHERE command_id=p_command AND generation>p_generation) THEN
        RAISE EXCEPTION 'current original shortfall approval required' USING ERRCODE='55000'; END IF;
    IF a.reviewer=session_user OR has_function_privilege(session_user,
        'meton_ledger.approve_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,bigint,integer,text,text,timestamptz,timestamptz)','EXECUTE') THEN
        RAISE EXCEPTION 'shortfall execution cannot approve' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.check_correction_deadline(p_permit,a.valid_until);
    SELECT * INTO effect FROM meton_ledger.restored_shortfall_effects WHERE command_id=p_command;
    IF FOUND THEN
        IF (effect.generation,effect.review_digest) IS DISTINCT FROM (p_generation,p_digest) THEN
            RAISE EXCEPTION 'different original shortfall effect' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.find_restored_shortfall_approval(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command,p_generation,p_digest);
    END IF;
    IF EXISTS(SELECT FROM meton_ledger.text_shortfall_resolutions WHERE command_id=p_command) THEN
        RAISE EXCEPTION 'legacy shortfall result cannot be adopted' USING ERRCODE='55000'; END IF;
    result:=meton_ledger.cover_text_shortfall_core(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,
        a.item_id,a.basis_event,p_command,a.case_id,a.attempt_id,a.original_digest,p_permit);
    PERFORM meton_ledger.check_correction_deadline(p_permit,a.valid_until);
    INSERT INTO meton_ledger.restored_shortfall_effects VALUES(p_command,p_generation,p_digest,session_user,p_permit,clock_timestamp());
    RETURN meton_ledger.find_restored_shortfall_approval(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_command,p_generation,p_digest);
END $$;

-- 资金效果和当前批准同事务成立；原费用修订仍由 281 的守恒约束负责。
CREATE FUNCTION meton_ledger.check_restored_shortfall_effect() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.restored_shortfall_approvals%ROWTYPE; r meton_ledger.text_shortfall_resolutions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT a FROM meton_ledger.restored_shortfall_approvals WHERE command_id=NEW.command_id AND generation=NEW.generation;
    SELECT * INTO STRICT r FROM meton_ledger.text_shortfall_resolutions WHERE command_id=NEW.command_id;
    IF (r.request_id,r.item_id,r.basis_event,r.case_id,r.attempt_id,r.approval_digest,r.executor)
        IS DISTINCT FROM (a.request_id,a.item_id,a.basis_event,a.case_id,a.attempt_id,a.original_digest,NEW.executor) OR
        NEW.executor<>session_user OR NEW.executor=a.reviewer OR NEW.review_digest<>a.review_digest OR
        EXISTS(SELECT FROM meton_ledger.restored_shortfall_approvals WHERE command_id=NEW.command_id AND generation>NEW.generation) THEN
        RAISE EXCEPTION 'invalid restored shortfall effect' USING ERRCODE='23514'; END IF;
    PERFORM meton_ledger.check_correction_deadline(NEW.permit_until,a.valid_until);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER complete_restored_shortfall AFTER INSERT ON meton_ledger.restored_shortfall_effects
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_restored_shortfall_effect();
ALTER TABLE meton_ledger.restored_shortfall_effects ENABLE ALWAYS TRIGGER complete_restored_shortfall;

REVOKE ALL ON FUNCTION meton_ledger.require_restored_shortfall_basis(uuid,uuid,uuid),
    meton_ledger.find_restored_shortfall_approval(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,integer,text),
    meton_ledger.approve_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,bigint,integer,text,text,timestamptz,timestamptz),
    meton_ledger.cover_restored_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,integer,text,timestamptz),
    meton_ledger.check_restored_shortfall_effect() FROM PUBLIC;
