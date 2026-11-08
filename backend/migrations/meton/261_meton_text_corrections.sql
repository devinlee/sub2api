-- 消费纠正引用原费用和原来源批次。批准、资金执行和供应成本确认各自需要独立权限。
CREATE TABLE meton_ledger.text_correction_decisions (
    decision uuid PRIMARY KEY CHECK(decision<>'00000000-0000-0000-0000-000000000000'),
    request_id uuid NOT NULL, item_id uuid NOT NULL, basis uuid NOT NULL REFERENCES meton_ledger.text_postings(report_event),
    version integer NOT NULL CHECK(version>0), final boolean NOT NULL, sources jsonb NOT NULL,
    amount numeric(20,8) NOT NULL CHECK(amount>0 AND amount<=999999999999.99999999), recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(request_id,item_id,version), FOREIGN KEY(request_id,item_id,basis) REFERENCES meton_ledger.text_fee_reports(request_id,item_id,event_id)
);
CREATE TABLE meton_ledger.text_corrections (
    decision uuid PRIMARY KEY REFERENCES meton_ledger.text_correction_decisions,
    journal uuid NOT NULL UNIQUE REFERENCES meton_ledger.events(event_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE meton_ledger.text_fee_disputes (
    evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid NOT NULL REFERENCES meton_ledger.text_requests, item_id uuid NOT NULL,
    decision uuid NOT NULL REFERENCES meton_ledger.text_correction_decisions, reported_event uuid NOT NULL,
    evidence jsonb NOT NULL, fingerprint bytea NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(request_id,item_id,fingerprint)
);
DO $migration$
DECLARE relation text;
BEGIN
    FOREACH relation IN ARRAY ARRAY['text_correction_decisions','text_corrections','text_fee_disputes'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',relation);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',relation);
    END LOOP;
END $migration$;

-- 259 的金额约束同时引用 kind 和 amount，数据库生成的名称不等于旧单列约束名。
DO $migration$
DECLARE old_amount name;
BEGIN
    SELECT conname INTO STRICT old_amount FROM pg_constraint WHERE conrelid='meton_ledger.events'::regclass AND contype='c'
        AND pg_get_constraintdef(oid) LIKE '%text_charge%' AND pg_get_constraintdef(oid) LIKE '%amount%';
    EXECUTE format('ALTER TABLE meton_ledger.events DROP CONSTRAINT %I',old_amount);
END $migration$;
ALTER TABLE meton_ledger.events DROP CONSTRAINT events_kind_check,
    ADD CONSTRAINT events_kind_check CHECK(kind IN ('grant','purchase','text_charge','text_revision','text_correction')),
    ADD CONSTRAINT events_signed_amount_check CHECK(amount BETWEEN -999999999999.99999999 AND 999999999999.99999999 AND
        CASE WHEN kind IN ('grant','purchase','text_correction') THEN amount>0 WHEN kind='text_charge' THEN amount<0 ELSE amount<>0 END);

-- 正额纠正的资金流水必须由原裁决的执行产生。其余资金事件继续沿用已有的提交期校验和触发器。
DO $migration$
DECLARE body text:=pg_get_functiondef('meton_ledger.check_journal_backing()'::regprocedure);
    anchor text:='    ELSIF EXISTS (SELECT FROM meton_ledger.text_postings';
    addition text:=$code$    ELSIF NEW.kind='text_correction' THEN
        IF EXISTS (SELECT FROM meton_ledger.text_corrections x JOIN meton_ledger.text_correction_decisions d USING(decision)
            JOIN meton_ledger.text_requests r USING(request_id) WHERE x.journal=NEW.event_id AND d.decision=NEW.origin_ref AND NEW.operation_id=d.decision
            AND r.source_marker=NEW.source_marker AND r.environment=NEW.environment AND r.source=NEW.source AND NEW.amount=d.amount) THEN RETURN NULL; END IF;
$code$;
BEGIN
    IF length(body)-length(replace(body,anchor,''))<>length(anchor) THEN RAISE EXCEPTION '259 journal signature changed'; END IF;
    EXECUTE replace(body,anchor,addition||anchor);
END $migration$;

CREATE FUNCTION meton_ledger.correction_sources(proposed jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE line jsonb; canonical jsonb;
BEGIN
    IF jsonb_typeof(proposed) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'source list required' USING ERRCODE='22023'; END IF;
    IF jsonb_array_length(proposed)=0 THEN RAISE EXCEPTION 'empty correction' USING ERRCODE='22023'; END IF;
    FOR line IN SELECT value FROM jsonb_array_elements(proposed) LOOP
        IF jsonb_typeof(line)<>'object' OR jsonb_typeof(line->'amount') IS DISTINCT FROM 'string' OR jsonb_typeof(line->'credit_event') IS DISTINCT FROM 'string'
            OR line-'credit_event'-'amount'<>'{}'::jsonb OR line->>'credit_event' !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
            OR line->>'credit_event'='00000000-0000-0000-0000-000000000000' OR line->>'amount' !~ '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$'
            OR line->>'amount'='0.00000000' THEN RAISE EXCEPTION 'invalid original source quantity' USING ERRCODE='22023'; END IF;
    END LOOP;
    SELECT jsonb_agg(value ORDER BY (value->>'credit_event')::uuid) INTO canonical FROM jsonb_array_elements(proposed)
        HAVING count(*)=count(DISTINCT value->>'credit_event');
    IF canonical IS NULL THEN RAISE EXCEPTION 'duplicate correction source' USING ERRCODE='22023'; END IF;
    RETURN canonical;
END $$;

-- 每一批的上限是该费项沿历次供应修订的原净扣费，减去此前已执行的商业纠正。
CREATE FUNCTION meton_ledger.correction_fits(p_request uuid,p_item uuid,proposed jsonb)
RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    WITH charged AS (
        SELECT s.credit_event,sum(s.charged) AS amount FROM meton_ledger.text_spend_splits s
        JOIN meton_ledger.text_fee_reports f ON f.event_id=s.report_event
        WHERE s.request_id=p_request AND f.item_id=p_item GROUP BY s.credit_event
    ), returned AS (
        SELECT (line->>'credit_event')::uuid AS credit_event,sum((line->>'amount')::numeric) AS amount
        FROM meton_ledger.text_correction_decisions d JOIN meton_ledger.text_corrections x USING(decision)
        CROSS JOIN LATERAL jsonb_array_elements(d.sources) line
        WHERE d.request_id=p_request AND d.item_id=p_item GROUP BY 1
    )
    SELECT NOT EXISTS (SELECT FROM jsonb_array_elements(proposed) line LEFT JOIN charged c ON c.credit_event=(line->>'credit_event')::uuid
        LEFT JOIN returned r ON r.credit_event=c.credit_event WHERE c.credit_event IS NULL OR (line->>'amount')::numeric>c.amount-coalesce(r.amount,0))
$$;

CREATE FUNCTION meton_ledger.find_text_decision(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_basis uuid,p_decision uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('origin',f.report->'origin','item',d.item_id,'basis',d.basis,'decision',d.decision,'version',d.version,
                              'final',d.final,'sources',d.sources,'amount',d.amount::text)
    FROM meton_ledger.text_correction_decisions d
    CROSS JOIN LATERAL (SELECT meton_ledger.find_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis) AS report) f
    WHERE (d.decision,d.request_id,d.item_id,d.basis)=(p_decision,p_request,p_item,p_basis) AND f.report IS NOT NULL
$$;
CREATE FUNCTION meton_ledger.find_text_correction(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_basis uuid,p_decision uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('approval',a.receipt,'journal',x.journal) FROM meton_ledger.text_corrections x
    CROSS JOIN LATERAL (SELECT meton_ledger.find_text_decision(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis,p_decision) AS receipt) a
    WHERE x.decision=p_decision AND a.receipt IS NOT NULL
$$;
CREATE FUNCTION meton_ledger.approve_text_correction(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_basis uuid,p_decision uuid,p_version integer,p_final boolean,p_sources jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE lines jsonb; original jsonb; last_ruling meton_ledger.text_correction_decisions%ROWTYPE; total numeric;
BEGIN
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF num_nulls(p_item,p_basis,p_decision,p_version,p_final)>0 OR p_version<1 OR
        '00000000-0000-0000-0000-000000000000'::uuid IN (p_item,p_basis,p_decision) THEN RAISE EXCEPTION 'invalid decision' USING ERRCODE='22023'; END IF;
    lines:=meton_ledger.correction_sources(p_sources);
    original:=meton_ledger.find_text_decision(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis,p_decision);
    IF original IS NOT NULL THEN
        IF (original->'sources',(original->>'version')::integer,(original->>'final')::boolean) IS DISTINCT FROM (lines,p_version,p_final) THEN
            RAISE EXCEPTION 'different original decision' USING ERRCODE='23505'; END IF;
        RETURN original;
    END IF;
    IF NOT EXISTS (SELECT FROM meton_ledger.latest_text_fees WHERE (request_id,item_id,event_id)=(p_request,p_item,p_basis)) THEN
        RAISE EXCEPTION 'latest original settlement required' USING ERRCODE='55000'; END IF;
    SELECT * INTO last_ruling FROM meton_ledger.text_correction_decisions WHERE request_id=p_request AND item_id=p_item ORDER BY version DESC LIMIT 1;
    IF coalesce(last_ruling.final,false) OR p_version<>coalesce(last_ruling.version,0)+1 OR
        (last_ruling.decision IS NOT NULL AND NOT EXISTS(SELECT FROM meton_ledger.text_corrections WHERE decision=last_ruling.decision)) THEN
        RAISE EXCEPTION 'final or pending decision, or version mismatch' USING ERRCODE='23505'; END IF;
    IF NOT meton_ledger.correction_fits(p_request,p_item,lines) THEN RAISE EXCEPTION 'outside original net charge' USING ERRCODE='23514'; END IF;
    SELECT sum((value->>'amount')::numeric) INTO total FROM jsonb_array_elements(lines);
    INSERT INTO meton_ledger.text_correction_decisions(decision,request_id,item_id,basis,version,final,sources,amount)
        VALUES(p_decision,p_request,p_item,p_basis,p_version,p_final,lines,total);
    RETURN meton_ledger.find_text_decision(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis,p_decision);
END $$;

CREATE FUNCTION meton_ledger.apply_text_correction(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_basis uuid,p_decision uuid,p_version integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_ledger.text_correction_decisions%ROWTYPE; h meton_ledger.text_hold_receipt; original jsonb; line jsonb;
    ref uuid:=gen_random_uuid(); seq bigint; native numeric;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    SELECT * INTO d FROM meton_ledger.text_correction_decisions WHERE (decision,request_id,item_id,basis,version)=(p_decision,p_request,p_item,p_basis,p_version);
    IF NOT FOUND THEN RAISE EXCEPTION 'original approved decision required' USING ERRCODE='55000'; END IF;
    original:=meton_ledger.find_text_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis,p_decision);
    IF original IS NOT NULL THEN RETURN original; END IF;
    IF NOT meton_ledger.correction_fits(p_request,p_item,d.sources) THEN RAISE EXCEPTION 'outside original net charge' USING ERRCODE='23514'; END IF;
    SELECT e.balance_after INTO STRICT native FROM meton_ledger.accounts a JOIN meton_ledger.events e ON e.source_marker=a.source_marker AND e.sequence=a.last_sequence
        WHERE a.source_marker=h.source_marker;
    FOR line IN SELECT value FROM jsonb_array_elements(d.sources) LOOP
        UPDATE meton_ledger.lots SET remaining=remaining+(line->>'amount')::numeric WHERE credit_event=(line->>'credit_event')::uuid;
        IF NOT FOUND THEN RAISE EXCEPTION 'missing original credit lot' USING ERRCODE='23514'; END IF;
    END LOOP;
    UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=h.source_marker RETURNING last_sequence INTO STRICT seq;
    INSERT INTO meton_ledger.text_corrections(decision,journal) VALUES(d.decision,ref);
    INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
        VALUES(ref,p_env,p_source,h.source_marker,d.decision,'text_correction',d.decision,seq,d.amount,native,native+d.amount);
    RETURN meton_ledger.find_text_correction(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_basis,p_decision);
END $$;

-- 已批准的纠正会阻止同一费项重新自动结算。真正重复的已入账终值仍可返回原回执。
CREATE FUNCTION meton_ledger.disputed_decision(p_request uuid,p_item uuid)
RETURNS uuid LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT d.decision FROM meton_ledger.text_correction_decisions d WHERE d.request_id=p_request AND
        (d.item_id=p_item OR (d.final AND EXISTS(SELECT FROM meton_ledger.text_fee_endings WHERE request_id=p_request)
                          AND NOT EXISTS(SELECT FROM meton_ledger.text_fee_reports WHERE request_id=p_request AND item_id=p_item)))
    ORDER BY (d.item_id=p_item) DESC,d.version DESC,d.decision LIMIT 1
$$;
CREATE FUNCTION meton_ledger.find_text_dispute(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_event uuid,p_evidence uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('state','review_required','origin',jsonb_build_object('environment',h.environment,'source',h.source,'user',h.meton_user,
        'account',h.account,'source_marker',h.source_marker,'caller',h.caller,'operation_id',h.operation_id,'source_request_id',h.request_id),
        'item',s.item_id,'reported_event',s.reported_event,'decision',s.decision,'evidence_id',s.evidence_id,'evidence',s.evidence)
    FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation) h JOIN meton_ledger.text_fee_disputes s USING(request_id)
    WHERE h.request_id=p_request AND (s.item_id,s.reported_event,s.evidence_id)=(p_item,p_event,p_evidence)
$$;
CREATE FUNCTION meton_ledger.keep_fee_dispute(h meton_ledger.text_hold_receipt,p_epoch bigint,p_item uuid,p_event uuid,p_decision uuid,payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE digest_value bytea:=sha256(convert_to(payload::text,'UTF8')); s meton_ledger.text_fee_disputes%ROWTYPE;
BEGIN
    INSERT INTO meton_ledger.text_fee_disputes(request_id,item_id,decision,reported_event,evidence,fingerprint)
        VALUES(h.request_id,p_item,p_decision,p_event,payload,digest_value) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT s FROM meton_ledger.text_fee_disputes d WHERE d.request_id=h.request_id AND d.item_id=p_item AND d.fingerprint=digest_value;
    IF s.evidence<>payload OR s.reported_event<>p_event THEN RAISE EXCEPTION 'different dispute evidence' USING ERRCODE='23505'; END IF;
    RETURN meton_ledger.find_text_dispute(h.environment,h.source,p_epoch,h.meton_user,h.account,h.source_marker,h.caller,h.operation_id,
                                         h.request_id,p_item,p_event,s.evidence_id);
END $$;
-- 原调用方可能没有收到证据编号。按原费项、原回报号列出全部矛盾证据，不触发补偿或费用执行。
CREATE FUNCTION meton_ledger.list_text_disputes(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT coalesce((SELECT jsonb_agg(meton_ledger.find_text_dispute(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,
                            p_request,p_item,p_event,s.evidence_id) ORDER BY s.recorded_at,s.evidence_id)
        FROM meton_ledger.text_fee_disputes s WHERE (s.request_id,s.item_id,s.reported_event)=(h.request_id,p_item,p_event)), '[]'::jsonb)
    FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation) h WHERE h.request_id=p_request
$$;
CREATE FUNCTION meton_ledger.review_adjudicated_fee(h meton_ledger.text_hold_receipt,p_epoch bigint,p_item uuid,p_event uuid,p_revision integer,
    p_price text,p_unit text,p_amount text,p_previous uuid,p_proof uuid,p_final_events uuid[])
RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE decision_id uuid; found_fee meton_ledger.text_fee_reports%ROWTYPE; manifest uuid[]; payload jsonb;
BEGIN
    decision_id:=meton_ledger.disputed_decision(h.request_id,p_item);
    IF decision_id IS NULL THEN RETURN NULL; END IF;
    IF (p_proof IS NULL)<>(p_final_events IS NULL) THEN RAISE EXCEPTION 'incomplete terminal evidence' USING ERRCODE='22023'; END IF;
    IF p_proof IS NOT NULL THEN
        IF NOT has_function_privilege(session_user,'meton_ledger.end_text_fees(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid[])','EXECUTE') THEN
            RAISE EXCEPTION 'terminal proof role required' USING ERRCODE='42501'; END IF;
        SELECT array_agg(v ORDER BY v) INTO manifest FROM unnest(p_final_events) v;
    END IF;
    SELECT f.* INTO found_fee FROM meton_ledger.text_fee_reports f JOIN meton_ledger.text_postings p ON p.report_event=f.event_id
        WHERE (f.request_id,f.item_id,f.event_id)=(h.request_id,p_item,p_event);
    IF FOUND AND (found_fee.revision,found_fee.amount::text,found_fee.previous_event,h.price_version,h.unit)
        IS NOT DISTINCT FROM (p_revision,p_amount,p_previous,p_price,p_unit)
        AND (p_proof IS NULL OR EXISTS (SELECT FROM meton_ledger.text_fee_endings e
            WHERE e.request_id=h.request_id AND e.proof=p_proof AND e.final_events=manifest)) THEN RETURN NULL; END IF;
    payload:=jsonb_build_object('kind','fee','event',p_event,'revision',p_revision,'price',p_price,'unit',p_unit,'amount',p_amount,
                                'previous',p_previous,'proof',p_proof,'final_events',manifest);
    RETURN meton_ledger.keep_fee_dispute(h,p_epoch,p_item,p_event,decision_id,payload);
END $$;

-- 复用 259 的原费项执行入口和授权。发生冲突时提交证据并返回待核对，不能在同一事务抛错而回滚证据。
DO $migration$
DECLARE body text:=pg_get_functiondef('meton_ledger.post_text_fee(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,integer,text,text,text,uuid,uuid,uuid[])'::regprocedure);
    anchor text:='    IF (p_price,p_unit) IS DISTINCT FROM (h.price_version,h.unit)';
    addition text:=$code$    original:=meton_ledger.review_adjudicated_fee(h,p_epoch,p_item,p_event,p_revision,p_price,p_unit,p_amount,p_previous,p_proof,p_final_events);
    IF original IS NOT NULL THEN RETURN original; END IF;
$code$;
BEGIN
    IF length(body)-length(replace(body,anchor,''))<>length(anchor) THEN RAISE EXCEPTION '259 posting signature changed'; END IF;
    EXECUTE replace(body,anchor,addition||anchor);
END $migration$;

CREATE FUNCTION meton_ledger.note_late_success(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_event uuid,p_proof uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; decision_id uuid;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF num_nulls(p_item,p_event,p_proof)>0 OR '00000000-0000-0000-0000-000000000000'::uuid IN (p_item,p_event,p_proof) THEN
        RAISE EXCEPTION 'original execution evidence required' USING ERRCODE='22023'; END IF;
    decision_id:=meton_ledger.disputed_decision(p_request,p_item);
    IF decision_id IS NULL THEN RAISE EXCEPTION 'accepted decision required' USING ERRCODE='55000'; END IF;
    RETURN meton_ledger.keep_fee_dispute(h,p_epoch,p_item,p_event,decision_id,jsonb_build_object('kind','execution_success','event',p_event,'proof',p_proof));
END $$;
REVOKE ALL ON FUNCTION meton_ledger.correction_sources(jsonb),meton_ledger.correction_fits(uuid,uuid,jsonb),meton_ledger.disputed_decision(uuid,uuid),
    meton_ledger.keep_fee_dispute(meton_ledger.text_hold_receipt,bigint,uuid,uuid,uuid,jsonb),
    meton_ledger.review_adjudicated_fee(meton_ledger.text_hold_receipt,bigint,uuid,uuid,integer,text,text,text,uuid,uuid,uuid[]),
    meton_ledger.find_text_decision(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid),
    meton_ledger.find_text_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid),
    meton_ledger.approve_text_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,integer,boolean,jsonb),
    meton_ledger.apply_text_correction(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,integer),
    meton_ledger.find_text_dispute(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid),
    meton_ledger.list_text_disputes(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid),
    meton_ledger.note_late_success(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC;
