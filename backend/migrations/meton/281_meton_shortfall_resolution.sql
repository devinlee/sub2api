-- 原差额的资金覆盖是独立处置，不修改供应用量、原费用或首次完成。
CREATE TABLE meton_ledger.text_shortfall_resolutions (
    command_id uuid PRIMARY KEY CHECK(command_id<>'00000000-0000-0000-0000-000000000000'),
    request_id uuid NOT NULL REFERENCES meton_ledger.text_requests,
    item_id uuid NOT NULL, basis_event uuid NOT NULL,
    case_id uuid NOT NULL CHECK(case_id<>'00000000-0000-0000-0000-000000000000'),
    attempt_id uuid NOT NULL CHECK(attempt_id<>'00000000-0000-0000-0000-000000000000'),
    approval_digest text NOT NULL CHECK(approval_digest ~ '^[a-f0-9]{64}$'),
    state text NOT NULL CHECK(state IN ('covered','funds_unavailable')),
    missing numeric(20,8) NOT NULL CHECK(missing>0), available_before numeric(20,8) NOT NULL CHECK(available_before>=0),
    event_id uuid UNIQUE REFERENCES meton_ledger.text_postings(report_event) DEFERRABLE INITIALLY DEFERRED,
    executor name NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(request_id,item_id,basis_event) REFERENCES meton_ledger.text_fee_reports(request_id,item_id,event_id),
    CHECK((state='covered')=(event_id IS NOT NULL)),
    CHECK(CASE state WHEN 'covered' THEN available_before>=missing ELSE available_before<missing END)
);
CREATE UNIQUE INDEX one_shortfall_cover ON meton_ledger.text_shortfall_resolutions(basis_event) WHERE state='covered';
CREATE INDEX shortfall_original ON meton_ledger.text_shortfall_resolutions(request_id,item_id,basis_event);
CREATE TRIGGER immutable_shortfall_resolution BEFORE UPDATE OR DELETE ON meton_ledger.text_shortfall_resolutions
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.text_shortfall_resolutions ENABLE ALWAYS TRIGGER immutable_shortfall_resolution;
REVOKE ALL ON meton_ledger.text_shortfall_resolutions FROM PUBLIC;

-- 只读按完整归属和原子命令查回，即使余额后来变化也不改写原“未执行”回执。
CREATE FUNCTION meton_ledger.find_text_shortfall(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_caller text,p_operation uuid,p_request uuid,p_command uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('version',1,'command_id',s.command_id,'case_id',s.case_id,'attempt_id',s.attempt_id,
        'approval_digest',s.approval_digest,'state',s.state,'missing',s.missing::text,'available_before',s.available_before::text,
        'basis',meton_ledger.find_text_posting(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,s.item_id,s.basis_event),
        'result',CASE WHEN s.event_id IS NOT NULL THEN meton_ledger.find_text_posting(p_env,p_source,p_epoch,p_user,p_account,p_marker,
            p_caller,p_operation,p_request,s.item_id,s.event_id) END)
    FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation) h
    JOIN meton_ledger.text_shortfall_resolutions s USING(request_id)
    WHERE h.request_id=p_request AND s.command_id=p_command
$$;

-- 结构校验不要求重新开放恢复栅栏；恢复材料必须已经包含原费用、修订和逐来源分配。
CREATE FUNCTION meton_ledger.check_shortfall_resolution() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE prior meton_ledger.text_fee_reports%ROWTYPE; paid meton_ledger.text_postings%ROWTYPE;
    next_fee meton_ledger.text_fee_reports%ROWTYPE; next_paid meton_ledger.text_postings%ROWTYPE;
BEGIN
    SELECT f.* INTO STRICT prior FROM meton_ledger.text_fee_reports f WHERE f.event_id=NEW.basis_event;
    SELECT p.* INTO STRICT paid FROM meton_ledger.text_postings p WHERE p.report_event=NEW.basis_event;
    IF NEW.item_id<>NEW.request_id OR (prior.request_id,prior.item_id) IS DISTINCT FROM (NEW.request_id,NEW.item_id)
        OR prior.state NOT IN ('final','revised') OR paid.uncovered<>NEW.missing OR paid.uncovered<=0
        OR NOT EXISTS(SELECT FROM meton_ledger.text_fee_endings WHERE request_id=NEW.request_id) THEN
        RAISE EXCEPTION 'invalid original shortfall' USING ERRCODE='23514'; END IF;
    IF NEW.state='funds_unavailable' THEN RETURN NEW; END IF;
    SELECT f.* INTO STRICT next_fee FROM meton_ledger.text_fee_reports f WHERE f.event_id=NEW.event_id;
    SELECT p.* INTO STRICT next_paid FROM meton_ledger.text_postings p WHERE p.report_event=NEW.event_id;
    IF (next_fee.request_id,next_fee.item_id,next_fee.previous_event,next_fee.revision,next_fee.state,next_fee.amount)
        IS DISTINCT FROM (NEW.request_id,NEW.item_id,NEW.basis_event,prior.revision+1,'revised'::text,prior.amount)
        OR next_paid.funded<>prior.amount OR next_paid.uncovered<>0 OR next_paid.funded_change<>NEW.missing
        OR NOT EXISTS(SELECT FROM meton_ledger.text_supplements WHERE request_id=NEW.request_id AND reason='fee'
            AND operation=NEW.event_id AND amount=NEW.missing AND covered)
        OR EXISTS(SELECT FROM meton_ledger.text_spend_splits s WHERE s.report_event=NEW.event_id AND
            (s.charged<=0 OR s.held_used<>s.charged OR NOT EXISTS(SELECT FROM meton_ledger.text_supplement_splits a
                WHERE a.request_id=NEW.request_id AND a.reason='fee' AND a.operation=NEW.event_id AND a.ordinal=s.ordinal
                    AND a.credit_event=s.credit_event AND a.amount=s.charged))) THEN
        RAISE EXCEPTION 'shortfall receipt lacks original accounting' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER complete_shortfall_resolution AFTER INSERT ON meton_ledger.text_shortfall_resolutions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_shortfall_resolution();
ALTER TABLE meton_ledger.text_shortfall_resolutions ENABLE ALWAYS TRIGGER complete_shortfall_resolution;

CREATE FUNCTION meton_ledger.cover_text_shortfall(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
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
REVOKE ALL ON FUNCTION meton_ledger.find_text_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid),
    meton_ledger.cover_text_shortfall(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,timestamptz),
    meton_ledger.check_shortfall_resolution() FROM PUBLIC;
