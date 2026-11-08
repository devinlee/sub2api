-- 费用与入账共用 255 的资金流水、账户序号、原生余额触发器及待投递事件。
ALTER TABLE meton_ledger.events DROP CONSTRAINT events_kind_check, DROP CONSTRAINT events_amount_check,
    ADD CHECK (kind IN ('grant','purchase','text_charge','text_revision')),
    ADD CHECK (amount BETWEEN -999999999999.99999999 AND 999999999999.99999999 AND
        CASE WHEN kind IN ('grant','purchase') THEN amount>0 WHEN kind='text_charge' THEN amount<0 ELSE amount<>0 END),
    ADD CHECK (balance_after>=0);
-- 旧外键要求每笔资金流水都新建一笔来源。扣费引用已存在的批次，不能为它虚造一批额度。
DO $migration$
DECLARE old_fk name;
BEGIN
    SELECT conname INTO STRICT old_fk FROM pg_constraint WHERE conrelid='meton_ledger.events'::regclass
        AND contype='f' AND confrelid='meton_ledger.lots'::regclass AND condeferrable AND condeferred;
    EXECUTE format('ALTER TABLE meton_ledger.events DROP CONSTRAINT %I',old_fk);
END $migration$;
CREATE TRIGGER keep_original_lot BEFORE DELETE OR UPDATE OF credit_event ON meton_ledger.lots
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();

CREATE TABLE meton_ledger.text_supplements (
    request_id uuid NOT NULL REFERENCES meton_ledger.text_requests, reason text NOT NULL CHECK(reason IN ('estimate','fee')),
    operation uuid NOT NULL CHECK(operation<>'00000000-0000-0000-0000-000000000000'),
    amount numeric(20,8) NOT NULL CHECK(amount>0 AND amount<=999999999999.99999999), covered boolean NOT NULL,
    PRIMARY KEY(request_id,reason,operation)
);
CREATE TABLE meton_ledger.text_supplement_splits (
    request_id uuid NOT NULL, reason text NOT NULL, operation uuid NOT NULL, ordinal integer NOT NULL CHECK(ordinal>0),
    credit_event uuid NOT NULL REFERENCES meton_ledger.lots, amount numeric(20,8) NOT NULL CHECK(amount>0 AND amount<=999999999999.99999999),
    PRIMARY KEY(request_id,ordinal), UNIQUE(request_id,reason,operation,credit_event),
    FOREIGN KEY(request_id,reason,operation) REFERENCES meton_ledger.text_supplements
);
CREATE TABLE meton_ledger.text_postings (
    report_event uuid PRIMARY KEY REFERENCES meton_ledger.text_fee_reports, funded numeric(20,8) NOT NULL CHECK(funded>=0),
    uncovered numeric(20,8) NOT NULL CHECK(uncovered>=0), funded_change numeric(20,8) NOT NULL,
    journal_event uuid UNIQUE REFERENCES meton_ledger.events DEFERRABLE INITIALLY DEFERRED,
    CHECK ((funded_change=0)=(journal_event IS NULL))
);
CREATE TABLE meton_ledger.text_spend_splits (
    report_event uuid NOT NULL REFERENCES meton_ledger.text_postings DEFERRABLE INITIALLY DEFERRED,
    request_id uuid NOT NULL REFERENCES meton_ledger.text_requests, ordinal integer NOT NULL CHECK(ordinal>0),
    credit_event uuid NOT NULL REFERENCES meton_ledger.lots, charged numeric(20,8) NOT NULL CHECK(charged<>0), held_used numeric(20,8) NOT NULL,
    PRIMARY KEY(report_event,ordinal), CHECK (held_used=charged OR (charged<0 AND held_used=0))
);
CREATE INDEX text_spend_by_request ON meton_ledger.text_spend_splits(request_id,ordinal);
CREATE TABLE meton_ledger.text_fee_endings (
    request_id uuid PRIMARY KEY REFERENCES meton_ledger.text_requests, proof uuid NOT NULL UNIQUE CHECK(proof<>'00000000-0000-0000-0000-000000000000'),
    final_events uuid[] NOT NULL CHECK(cardinality(final_events)>0), recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE meton_ledger.text_tail_releases (
    request_id uuid NOT NULL REFERENCES meton_ledger.text_fee_endings, ordinal integer NOT NULL CHECK(ordinal>0),
    credit_event uuid NOT NULL REFERENCES meton_ledger.lots, amount numeric(20,8) NOT NULL CHECK(amount>0),
    PRIMARY KEY(request_id,ordinal)
);
DO $migration$
DECLARE relation text;
BEGIN
    FOREACH relation IN ARRAY ARRAY['text_supplements','text_supplement_splits','text_postings','text_spend_splits','text_fee_endings','text_tail_releases'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',relation);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',relation);
    END LOOP;
END $migration$;
CREATE VIEW meton_ledger.text_all_slices AS
    SELECT request_id,ordinal,credit_event,amount FROM meton_ledger.text_allocations
    UNION ALL SELECT request_id,ordinal,credit_event,amount FROM meton_ledger.text_supplement_splits;
CREATE FUNCTION meton_ledger.open_text_slices(p_request uuid)
RETURNS TABLE(ordinal integer,credit_event uuid,open_amount numeric) LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT a.ordinal,a.credit_event,a.amount
        -coalesce((SELECT sum(m.held_used) FROM meton_ledger.text_spend_splits m WHERE m.request_id=a.request_id AND m.ordinal=a.ordinal),0)
        -coalesce(r.amount,0)
    FROM meton_ledger.text_all_slices a LEFT JOIN meton_ledger.text_tail_releases r USING(request_id,ordinal)
    WHERE a.request_id=p_request AND NOT EXISTS (SELECT FROM meton_ledger.text_send_decisions d WHERE d.request_id=p_request AND d.state='cancelled_unsent')
$$;

CREATE VIEW meton_ledger.latest_text_fees AS
    SELECT DISTINCT ON (f.request_id,f.item_id) f.request_id,f.item_id,f.event_id,f.revision,f.amount,p.funded,p.uncovered
    FROM meton_ledger.text_fee_reports f JOIN meton_ledger.text_postings p ON p.report_event=f.event_id
    ORDER BY f.request_id,f.item_id,f.revision DESC;
CREATE FUNCTION meton_ledger.has_text_shortfall(p_marker uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.text_requests r JOIN meton_ledger.latest_text_fees f USING(request_id)
                  WHERE r.source_marker=p_marker AND f.uncovered>0)
$$;
CREATE FUNCTION meton_ledger.guard_text_shortfall() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid;
BEGIN
    IF TG_TABLE_NAME='lots' THEN
        SELECT e.source_marker INTO STRICT marker FROM meton_ledger.events e WHERE e.event_id=NEW.credit_event;
        -- S3 的运行入口同样先锁原账号；旧写者从批次先写时也不能跳过账户上的差额检查。
        PERFORM 1 FROM public.users u JOIN public.meton_managed_creations m ON m.remote_user=u.id WHERE m.source_marker=marker FOR UPDATE OF u;
    ELSIF TG_TABLE_NAME='text_send_decisions' THEN
        IF EXISTS (SELECT FROM meton_ledger.text_send_decisions WHERE request_id=NEW.request_id) THEN RETURN NEW; END IF;
        SELECT source_marker INTO STRICT marker FROM meton_ledger.text_requests WHERE request_id=NEW.request_id;
    ELSE marker:=NEW.source_marker;
    END IF;
    IF meton_ledger.has_text_shortfall(marker) THEN RAISE EXCEPTION 'unresolved source fee' USING ERRCODE='P5302'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER gap_before_reserve BEFORE INSERT ON meton_ledger.text_requests FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_text_shortfall();
CREATE TRIGGER gap_before_dispatch BEFORE INSERT ON meton_ledger.text_send_decisions FOR EACH ROW WHEN (NEW.state='dispatch_claimed')
    EXECUTE FUNCTION meton_ledger.guard_text_shortfall();
CREATE TRIGGER gap_before_new_refund_hold BEFORE UPDATE OF refund_held ON meton_ledger.lots FOR EACH ROW WHEN (NEW.refund_held>OLD.refund_held)
    EXECUTE FUNCTION meton_ledger.guard_text_shortfall();

-- 同一来源事务确认费用流水和逐批净变化。普通入账继续要求原来源批次存在。
CREATE FUNCTION meton_ledger.check_journal_backing() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NEW.kind IN ('grant','purchase') THEN
        IF EXISTS(SELECT FROM meton_ledger.lots WHERE credit_event=NEW.event_id) THEN RETURN NULL; END IF;
    ELSIF EXISTS (SELECT FROM meton_ledger.text_postings p JOIN meton_ledger.text_fee_reports f ON f.event_id=p.report_event
        JOIN meton_ledger.text_requests r USING(request_id) WHERE p.journal_event=NEW.event_id AND p.report_event=NEW.origin_ref
        AND NEW.operation_id=NEW.origin_ref AND r.source_marker=NEW.source_marker AND r.environment=NEW.environment AND r.source=NEW.source
        AND NEW.amount=-p.funded_change AND NEW.kind=CASE f.state WHEN 'final' THEN 'text_charge' WHEN 'revised' THEN 'text_revision' END) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'unbacked source event' USING ERRCODE='23514';
END $$;
CREATE CONSTRAINT TRIGGER complete_journal_backing AFTER INSERT ON meton_ledger.events DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_journal_backing();
CREATE FUNCTION meton_ledger.check_text_posting() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE f meton_ledger.text_fee_reports%ROWTYPE;
BEGIN
    SELECT * INTO STRICT f FROM meton_ledger.text_fee_reports WHERE event_id=NEW.report_event;
    IF f.state NOT IN ('final','revised') OR f.amount<>NEW.funded+NEW.uncovered OR NEW.funded_change<>(SELECT coalesce(sum(charged),0)
        FROM meton_ledger.text_spend_splits WHERE report_event=f.event_id) OR EXISTS (
        SELECT FROM meton_ledger.text_spend_splits m LEFT JOIN meton_ledger.text_all_slices a
        ON (a.request_id,a.ordinal,a.credit_event)=(m.request_id,m.ordinal,m.credit_event)
        WHERE m.report_event=f.event_id AND (m.request_id<>f.request_id OR a.ordinal IS NULL)) THEN
        RAISE EXCEPTION 'fee and source splits disagree' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER complete_fee_sources AFTER INSERT ON meton_ledger.text_postings DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_text_posting();

CREATE FUNCTION meton_ledger.lock_dispatched_fee(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid)
RETURNS meton_ledger.text_hold_receipt LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; remote_id bigint; native numeric; total numeric;
BEGIN
    remote_id:=meton_ledger.lock_text_owner(p_env,p_source,p_epoch,p_user,p_account,p_marker);
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request OR h.epoch_at_accept<>p_epoch OR h.state<>'dispatch_claimed' THEN
        RAISE EXCEPTION 'dispatched original required' USING ERRCODE='55000';
    END IF;
    SELECT balance INTO native FROM public.users WHERE id=remote_id AND frozen_balance=0;
    SELECT sum(l.remaining) INTO total FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=p_marker;
    IF native IS NULL OR native IS DISTINCT FROM total OR NOT EXISTS (SELECT FROM meton_ledger.accounts a JOIN meton_ledger.events e
        ON e.source_marker=a.source_marker AND e.sequence=a.last_sequence WHERE a.source_marker=p_marker AND a.unit=h.unit AND e.balance_after=native) THEN
        RAISE EXCEPTION 'source journal requires reconciliation' USING ERRCODE='23514';
    END IF;
    RETURN h;
END $$;

CREATE FUNCTION meton_ledger.extend_text_cover(h meton_ledger.text_hold_receipt,p_reason text,p_operation uuid,p_amount numeric)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE prior meton_ledger.text_supplements%ROWTYPE; available numeric; part numeric; unfilled numeric:=p_amount; lot record; pos integer; allowed boolean;
BEGIN
    SELECT * INTO prior FROM meton_ledger.text_supplements WHERE request_id=h.request_id AND reason=p_reason AND operation=p_operation;
    IF FOUND THEN
        IF prior.amount<>p_amount THEN RAISE EXCEPTION 'different supplement' USING ERRCODE='23505'; END IF;
        RETURN prior.covered;
    END IF;
    SELECT coalesce(sum(l.remaining-l.held-l.refund_held),0) INTO available FROM meton_ledger.events e JOIN meton_ledger.lots l ON l.credit_event=e.event_id
        WHERE e.source_marker=h.source_marker;
    allowed:=available>=p_amount AND NOT meton_ledger.has_text_shortfall(h.source_marker);
    INSERT INTO meton_ledger.text_supplements VALUES(h.request_id,p_reason,p_operation,p_amount,allowed);
    IF NOT allowed THEN RETURN false; END IF;
    SELECT coalesce(max(ordinal),0) INTO pos FROM meton_ledger.text_all_slices WHERE request_id=h.request_id;
    FOR lot IN SELECT l.credit_event,l.remaining-l.held-l.refund_held AS free FROM meton_ledger.events e JOIN meton_ledger.lots l ON l.credit_event=e.event_id
        WHERE e.source_marker=h.source_marker AND l.remaining>l.held+l.refund_held ORDER BY (e.kind='grant') DESC,e.sequence FOR UPDATE OF l LOOP
        part:=least(unfilled,lot.free);
        IF part>0 THEN
            pos:=pos+1;
            UPDATE meton_ledger.lots SET held=held+part WHERE credit_event=lot.credit_event;
            INSERT INTO meton_ledger.text_supplement_splits VALUES(h.request_id,p_reason,p_operation,pos,lot.credit_event,part);
            unfilled:=unfilled-part;
        END IF;
        EXIT WHEN unfilled=0;
    END LOOP;
    IF unfilled<>0 THEN RAISE EXCEPTION 'source availability changed' USING ERRCODE='40001'; END IF;
    RETURN true;
END $$;

CREATE FUNCTION meton_ledger.find_text_cover(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_proof uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('request',s.request_id,'operation',s.operation,'amount',s.amount::text,'covered',s.covered,
        'sources',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',a.ordinal,'credit_event',a.credit_event,'amount',a.amount::text) ORDER BY a.ordinal)
            FROM meton_ledger.text_supplement_splits a WHERE (a.request_id,a.reason,a.operation)=(s.request_id,s.reason,s.operation)),'[]'::jsonb))
    FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation) h JOIN meton_ledger.text_supplements s USING(request_id)
    WHERE h.request_id=p_request AND s.reason='estimate' AND s.operation=p_proof
$$;
CREATE FUNCTION meton_ledger.add_text_cover(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_proof uuid,p_price text,p_unit text,p_amount text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; original jsonb;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF num_nulls(p_proof,p_price,p_unit,p_amount)>0 OR p_proof='00000000-0000-0000-0000-000000000000' OR (p_price,p_unit) IS DISTINCT FROM (h.price_version,h.unit)
        OR p_amount !~ '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$' OR p_amount='0.00000000' THEN RAISE EXCEPTION 'invalid supplement' USING ERRCODE='22023'; END IF;
    original:=meton_ledger.find_text_cover(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_proof);
    IF original IS NOT NULL THEN
        IF original->>'amount'<>p_amount THEN RAISE EXCEPTION 'different supplement' USING ERRCODE='23505'; END IF;
        RETURN original;
    END IF;
    IF EXISTS(SELECT FROM meton_ledger.text_fee_endings WHERE request_id=p_request) THEN RAISE EXCEPTION 'fee list closed' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.extend_text_cover(h,'estimate',p_proof,p_amount::numeric);
    RETURN meton_ledger.find_text_cover(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_proof);
END $$;

CREATE FUNCTION meton_ledger.find_text_posting(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_item uuid,p_event uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    WITH original AS (SELECT meton_ledger.find_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_event) AS report)
    SELECT jsonb_build_object('report',o.report,'funded',p.funded::text,'uncovered',p.uncovered::text,'change',p.funded_change::text,'ledger_event',p.journal_event,
        'sources',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',m.ordinal,'credit_event',m.credit_event,'change',m.charged::text) ORDER BY m.ordinal)
            FROM meton_ledger.text_spend_splits m WHERE m.report_event=p.report_event),'[]'::jsonb))
    FROM original o JOIN meton_ledger.text_postings p ON p.report_event=p_event WHERE o.report IS NOT NULL
$$;
CREATE FUNCTION meton_ledger.find_text_ending(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('request',e.request_id,'proof',e.proof,'final_events',e.final_events,
        'released',coalesce((SELECT jsonb_agg(jsonb_build_object('ordinal',r.ordinal,'credit_event',r.credit_event,'amount',r.amount::text) ORDER BY r.ordinal DESC)
            FROM meton_ledger.text_tail_releases r WHERE r.request_id=e.request_id),'[]'::jsonb))
    FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation) h JOIN meton_ledger.text_fee_endings e USING(request_id)
    WHERE h.request_id=p_request
$$;
CREATE FUNCTION meton_ledger.end_text_fees(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_proof uuid,p_final_events uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actual uuid[]; expected uuid[]; original jsonb; slice record;
BEGIN
    PERFORM meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF p_proof IS NULL OR p_proof='00000000-0000-0000-0000-000000000000' OR coalesce(cardinality(p_final_events),0)=0 OR array_ndims(p_final_events)<>1 THEN
        RAISE EXCEPTION 'explicit final fee manifest required' USING ERRCODE='22023'; END IF;
    SELECT array_agg(DISTINCT v ORDER BY v) INTO expected FROM unnest(p_final_events) v WHERE v IS NOT NULL AND v<>'00000000-0000-0000-0000-000000000000';
    IF coalesce(cardinality(expected),0)<>cardinality(p_final_events) THEN RAISE EXCEPTION 'invalid final fee list' USING ERRCODE='22023'; END IF;
    original:=meton_ledger.find_text_ending(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF original IS NOT NULL THEN
        IF original->>'proof'<>p_proof::text OR original->'final_events'<>to_jsonb(expected) THEN RAISE EXCEPTION 'different terminal proof' USING ERRCODE='23505'; END IF;
        RETURN original;
    END IF;
    SELECT array_agg(event_id ORDER BY event_id) INTO actual FROM meton_ledger.latest_text_fees WHERE request_id=p_request;
    IF actual IS DISTINCT FROM expected OR EXISTS (SELECT FROM meton_ledger.text_fee_reports r LEFT JOIN meton_ledger.latest_text_fees f USING(request_id,item_id)
        WHERE r.request_id=p_request AND (f.event_id IS NULL OR r.revision>f.revision)) THEN RAISE EXCEPTION 'pending or unproved fee items' USING ERRCODE='55000'; END IF;
    INSERT INTO meton_ledger.text_fee_endings(request_id,proof,final_events) VALUES(p_request,p_proof,expected);
    FOR slice IN SELECT * FROM meton_ledger.open_text_slices(p_request) WHERE open_amount>0 ORDER BY ordinal DESC LOOP
        UPDATE meton_ledger.lots SET held=held-slice.open_amount WHERE credit_event=slice.credit_event;
        INSERT INTO meton_ledger.text_tail_releases VALUES(p_request,slice.ordinal,slice.credit_event,slice.open_amount);
    END LOOP;
    RETURN meton_ledger.find_text_ending(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
END $$;

-- 未知的迟到费项交核对。已关闭请求只能补录已知费项的旧观察或处理显式引用前一终值的修订。
CREATE FUNCTION meton_ledger.guard_late_observation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF EXISTS (SELECT FROM meton_ledger.text_fee_endings WHERE request_id=NEW.request_id) AND NOT EXISTS (
        SELECT FROM meton_ledger.latest_text_fees f WHERE f.request_id=NEW.request_id AND f.item_id=NEW.item_id AND f.revision>NEW.revision) THEN
        RAISE EXCEPTION 'observation after terminal evidence' USING ERRCODE='23505';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER observe_after_fee_ending BEFORE INSERT ON meton_ledger.text_fee_reports FOR EACH ROW WHEN (NEW.state='observed')
    EXECUTE FUNCTION meton_ledger.guard_late_observation();

-- 单一最终费项只提交其净变化。明确的原终局清单可随最后一笔在同一事务释放尾部。
CREATE FUNCTION meton_ledger.post_text_fee(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
        p_request uuid,p_item uuid,p_event uuid,p_revision integer,p_price text,p_unit text,p_amount text,p_previous uuid,p_proof uuid,p_final_events uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    h meton_ledger.text_hold_receipt; prior meton_ledger.latest_text_fees%ROWTYPE; kind text; existing jsonb; original jsonb;
    actual numeric; prior_amount numeric:=0; prior_funded numeric:=0; needed numeric; free_hold numeric; change numeric; left_to_apply numeric;
    part numeric; held_part numeric; funded numeric; journal uuid; native numeric; seq bigint; slice record; closed boolean;
BEGIN
    h:=meton_ledger.lock_dispatched_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request);
    IF num_nulls(p_item,p_event,p_revision,p_price,p_unit,p_amount)>0 OR p_revision<1 OR
        '00000000-0000-0000-0000-000000000000'::uuid IN (p_item,p_event) OR p_amount !~ '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$' THEN
        RAISE EXCEPTION 'invalid final fee' USING ERRCODE='22023';
    END IF;
    IF (p_price,p_unit) IS DISTINCT FROM (h.price_version,h.unit) THEN RAISE EXCEPTION 'wrong original price or unit' USING ERRCODE='23505'; END IF;
    IF (p_proof IS NULL)<>(p_final_events IS NULL) THEN RAISE EXCEPTION 'incomplete terminal evidence' USING ERRCODE='22023'; END IF;
    IF p_proof IS NOT NULL AND NOT has_function_privilege(session_user,
        'meton_ledger.end_text_fees(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid[])','EXECUTE') THEN
        RAISE EXCEPTION 'terminal proof role required' USING ERRCODE='42501';
    END IF;
    kind:=CASE WHEN p_previous IS NULL THEN 'final' ELSE 'revised' END;
    existing:=meton_ledger.find_text_posting(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_event);
    IF existing IS NOT NULL THEN
        original:=existing->'report'->'item';
        IF ROW(original->>'amount',(original->>'revision')::integer,original->>'state',original->>'previous_event_id')
            IS DISTINCT FROM ROW(p_amount,p_revision,kind,p_previous::text) THEN RAISE EXCEPTION 'different original fee' USING ERRCODE='23505'; END IF;
        IF p_proof IS NOT NULL THEN PERFORM meton_ledger.end_text_fees(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_proof,p_final_events); END IF;
        RETURN existing;
    END IF;
    SELECT EXISTS(SELECT FROM meton_ledger.text_fee_endings WHERE request_id=p_request) INTO closed;
    SELECT * INTO prior FROM meton_ledger.latest_text_fees WHERE request_id=p_request AND item_id=p_item;
    IF FOUND THEN
        IF p_previous IS DISTINCT FROM prior.event_id OR p_revision<=prior.revision THEN RAISE EXCEPTION 'explicit previous terminal fee required' USING ERRCODE='23505'; END IF;
        prior_amount:=prior.amount; prior_funded:=prior.funded;
    ELSIF p_previous IS NOT NULL OR closed THEN RAISE EXCEPTION 'unknown fee revision or closed request' USING ERRCODE='55000';
    END IF;
    IF EXISTS(SELECT FROM meton_ledger.text_fee_reports WHERE request_id=p_request AND item_id=p_item AND revision>=p_revision) THEN
        RAISE EXCEPTION 'fee revision conflict' USING ERRCODE='23505';
    END IF;
    actual:=p_amount::numeric;
    INSERT INTO meton_ledger.text_fee_reports(event_id,request_id,item_id,revision,state,amount,previous_event)
        VALUES(p_event,p_request,p_item,p_revision,kind,actual,p_previous);
    -- 提高终值只增加本次新增的真实费用。降低终值先消除未覆盖差额，再沿原费项返还多扣部分。
    needed:=CASE WHEN actual>=prior_amount THEN actual-prior_amount ELSE least(actual,prior_funded)-prior_funded END;
    change:=needed;
    IF needed>0 THEN
        SELECT coalesce(sum(open_amount),0) INTO free_hold FROM meton_ledger.open_text_slices(p_request);
        IF free_hold<needed THEN
            IF NOT meton_ledger.extend_text_cover(h,'fee',p_event,needed-free_hold) THEN change:=free_hold; END IF;
        END IF;
        left_to_apply:=change;
        FOR slice IN SELECT * FROM meton_ledger.open_text_slices(p_request) WHERE open_amount>0 ORDER BY ordinal LOOP
            EXIT WHEN left_to_apply=0;
            part:=least(slice.open_amount,left_to_apply);
            UPDATE meton_ledger.lots SET remaining=remaining-part,held=held-part WHERE credit_event=slice.credit_event;
            INSERT INTO meton_ledger.text_spend_splits VALUES(p_event,p_request,slice.ordinal,slice.credit_event,part,part);
            left_to_apply:=left_to_apply-part;
        END LOOP;
    ELSIF needed<0 THEN
        left_to_apply:=-needed;
        FOR slice IN SELECT m.ordinal,m.credit_event,sum(m.charged) AS paid FROM meton_ledger.text_spend_splits m
            JOIN meton_ledger.text_fee_reports f ON f.event_id=m.report_event
            WHERE m.request_id=p_request AND f.item_id=p_item GROUP BY m.ordinal,m.credit_event HAVING sum(m.charged)>0 ORDER BY m.ordinal DESC LOOP
            EXIT WHEN left_to_apply=0;
            part:=least(slice.paid,left_to_apply);
            held_part:=CASE WHEN closed THEN 0 ELSE part END;
            UPDATE meton_ledger.lots SET remaining=remaining+part,held=held+held_part WHERE credit_event=slice.credit_event;
            INSERT INTO meton_ledger.text_spend_splits VALUES(p_event,p_request,slice.ordinal,slice.credit_event,-part,-held_part);
            left_to_apply:=left_to_apply-part;
        END LOOP;
    END IF;
    IF coalesce(left_to_apply,0)<>0 THEN RAISE EXCEPTION 'incomplete fee sources' USING ERRCODE='23514'; END IF;
    funded:=prior_funded+change;
    IF change<>0 THEN journal:=gen_random_uuid(); END IF;
    INSERT INTO meton_ledger.text_postings VALUES(p_event,funded,actual-funded,change,journal);
    IF journal IS NOT NULL THEN
        UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=p_marker RETURNING last_sequence INTO STRICT seq;
        SELECT u.balance INTO STRICT native FROM public.users u JOIN public.meton_managed_creations m ON m.remote_user=u.id WHERE m.source_marker=p_marker;
        IF native-change IS DISTINCT FROM (SELECT sum(l.remaining) FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event
            WHERE e.source_marker=p_marker) THEN RAISE EXCEPTION 'fee source total mismatch' USING ERRCODE='23514'; END IF;
        INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
            VALUES(journal,p_env,p_source,p_marker,p_event,CASE kind WHEN 'final' THEN 'text_charge' ELSE 'text_revision' END,p_event,seq,-change,native,native-change);
    END IF;
    IF p_proof IS NOT NULL THEN PERFORM meton_ledger.end_text_fees(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_proof,p_final_events); END IF;
    RETURN meton_ledger.find_text_posting(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_event);
END $$;

REVOKE ALL ON meton_ledger.text_all_slices,meton_ledger.latest_text_fees FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.open_text_slices(uuid),meton_ledger.has_text_shortfall(uuid),meton_ledger.guard_text_shortfall(),
    meton_ledger.check_journal_backing(),meton_ledger.check_text_posting(),meton_ledger.guard_late_observation(),
    meton_ledger.lock_dispatched_fee(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid),meton_ledger.extend_text_cover(meton_ledger.text_hold_receipt,text,uuid,numeric),
    meton_ledger.find_text_cover(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid),
    meton_ledger.add_text_cover(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,text,text,text),
    meton_ledger.find_text_posting(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid),
    meton_ledger.find_text_ending(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid),
    meton_ledger.end_text_fees(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid[]),
    meton_ledger.post_text_fee(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,integer,text,text,text,uuid,uuid,uuid[]) FROM PUBLIC;

-- 保持原入账查询的用途。新增的负向流水只能作为原费项结算来读取。
CREATE OR REPLACE FUNCTION meton_ledger.find_credit(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_operation uuid)
RETURNS SETOF meton_ledger.events LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT e.* FROM public.meton_managed_fence f JOIN public.meton_managed_creations m ON f.environment=m.environment AND f.source=m.source AND f.epoch=m.epoch
    JOIN meton_ledger.events e ON e.source_marker=m.source_marker AND e.environment=m.environment AND e.source=m.source
    WHERE f.singleton AND f.enabled AND f.environment=p_env AND f.source=p_source AND f.epoch=p_epoch AND m.meton_user=p_user AND m.account=p_account
      AND m.source_marker=p_marker AND e.operation_id=p_operation AND e.kind IN ('grant','purchase')
      AND NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
$$;
DO $migration$
BEGIN
    IF EXISTS (SELECT FROM meton_ledger.text_fee_reports WHERE state<>'observed') THEN
        RAISE EXCEPTION 'historical terminal fee requires reconciliation' USING ERRCODE='23514';
    END IF;
END $migration$;
CREATE FUNCTION meton_ledger.check_terminal_posted() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT FROM meton_ledger.text_postings WHERE report_event=NEW.event_id) THEN RAISE EXCEPTION 'unposted terminal fee' USING ERRCODE='23514'; END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER terminal_has_posting AFTER INSERT ON meton_ledger.text_fee_reports DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW WHEN (NEW.state<>'observed') EXECUTE FUNCTION meton_ledger.check_terminal_posted();
CREATE FUNCTION meton_ledger.check_text_supplement() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE split_total numeric; wrong_source boolean;
BEGIN
    SELECT coalesce(sum(a.amount),0),coalesce(bool_or(e.source_marker<>r.source_marker OR o.ordinal IS NOT NULL),false) INTO split_total,wrong_source
      FROM meton_ledger.text_supplement_splits a JOIN meton_ledger.events e ON e.event_id=a.credit_event JOIN meton_ledger.text_requests r USING(request_id)
      LEFT JOIN meton_ledger.text_allocations o ON o.request_id=a.request_id AND o.ordinal=a.ordinal
      WHERE (a.request_id,a.reason,a.operation)=(NEW.request_id,NEW.reason,NEW.operation);
    IF wrong_source OR split_total<>(CASE WHEN NEW.covered THEN NEW.amount ELSE 0 END) THEN RAISE EXCEPTION 'unbacked supplement' USING ERRCODE='23514'; END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER complete_supplement AFTER INSERT ON meton_ledger.text_supplements DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_text_supplement();
REVOKE ALL ON FUNCTION meton_ledger.check_terminal_posted(),meton_ledger.check_text_supplement() FROM PUBLIC;
