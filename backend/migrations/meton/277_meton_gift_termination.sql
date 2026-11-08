-- 只有当前 Identity 最终关闭事实可授权此范围；申请、撤回和净余额均不是资金终止证明。
CREATE TABLE meton_ledger.gift_terminations (
    decision uuid PRIMARY KEY CHECK(decision<>'00000000-0000-0000-0000-000000000000'),
    source_marker uuid NOT NULL UNIQUE REFERENCES public.meton_managed_creations(source_marker),
    environment text NOT NULL, source text NOT NULL, epoch bigint NOT NULL CHECK(epoch>0),
    meton_user uuid NOT NULL, account uuid NOT NULL, creation uuid NOT NULL, dispatch uuid NOT NULL, remote_user bigint NOT NULL,
    eligibility uuid NOT NULL CHECK(eligibility<>'00000000-0000-0000-0000-000000000000'),
    registration uuid NOT NULL CHECK(registration<>'00000000-0000-0000-0000-000000000000'),
    identity_event uuid NOT NULL UNIQUE CHECK(identity_event<>'00000000-0000-0000-0000-000000000000'),
    security_version bigint NOT NULL CHECK(security_version>0), identity_epoch bigint NOT NULL CHECK(identity_epoch>0),
    cutoff_sequence bigint NOT NULL CHECK(cutoff_sequence>=0), recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(environment,source,eligibility)
);
CREATE TABLE meton_ledger.gift_retirements (
    effect uuid PRIMARY KEY, decision uuid NOT NULL REFERENCES meton_ledger.gift_terminations,
    credit_event uuid NOT NULL REFERENCES meton_ledger.lots, cause_event uuid REFERENCES meton_ledger.events,
    amount numeric(20,8) NOT NULL CHECK(amount>=0 AND amount<=999999999999.99999999),
    journal uuid UNIQUE REFERENCES meton_ledger.events DEFERRABLE INITIALLY DEFERRED,
    CHECK((amount=0 AND journal IS NULL) OR (amount>0 AND journal=effect))
);
CREATE UNIQUE INDEX gift_initial_retirement ON meton_ledger.gift_retirements(decision,credit_event) WHERE cause_event IS NULL;
CREATE UNIQUE INDEX gift_late_retirement ON meton_ledger.gift_retirements(decision,credit_event,cause_event) WHERE cause_event IS NOT NULL;
CREATE TRIGGER immutable_termination BEFORE UPDATE OR DELETE ON meton_ledger.gift_terminations FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TRIGGER immutable_retirement BEFORE UPDATE OR DELETE ON meton_ledger.gift_retirements FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
REVOKE ALL ON meton_ledger.gift_terminations,meton_ledger.gift_retirements FROM PUBLIC;

ALTER TABLE meton_ledger.events DROP CONSTRAINT events_kind_check,DROP CONSTRAINT events_signed_amount_check,
    ADD CONSTRAINT events_kind_check CHECK(kind IN ('grant','purchase','text_charge','text_revision','text_correction','gift_termination')),
    ADD CONSTRAINT events_signed_amount_check CHECK(amount BETWEEN -999999999999.99999999 AND 999999999999.99999999 AND
        CASE WHEN kind IN ('grant','purchase','text_correction') THEN amount>0 WHEN kind IN ('text_charge','gift_termination') THEN amount<0 ELSE amount<>0 END);

CREATE FUNCTION meton_ledger.gift_owner(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid)
RETURNS public.meton_managed_creations LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE;
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'current gift closure source required' USING ERRCODE='55000'; END IF;
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'gift closure source unavailable' USING ERRCODE='55000'; END IF;
    SELECT c.* INTO m FROM public.meton_managed_creations c JOIN public.meton_s1_funds_births b ON b.remote_user=c.remote_user AND b.operation=c.operation
        WHERE ROW(c.environment,c.source,c.epoch,c.meton_user,c.account,c.operation,c.dispatch,c.remote_user,c.source_marker)
            IS NOT DISTINCT FROM ROW(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker) FOR SHARE OF c;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown gift closure origin' USING ERRCODE='42501'; END IF;
    -- 与发放、预占和结算共用用户行锁；等待后复读，不拿旧快照批准终止。
    PERFORM 1 FROM public.users u WHERE u.id=m.remote_user AND u.deleted_at IS NULL AND u.role='user' AND u.restrict_public_groups
        AND u.password_hash='!meton-managed' AND u.email='meton-'||m.account::text||'@managed.invalid' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'gift closure user unavailable' USING ERRCODE='42501'; END IF;
    RETURN m;
END $$;

CREATE FUNCTION meton_ledger.gift_state(p_marker uuid,p_eligibility uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; u public.users%ROWTYPE; state text; stock numeric; held numeric; refunds numeric;
    pending bigint; gifts bigint; purchases bigint; other_grants bigint;
BEGIN
    SELECT * INTO STRICT m FROM public.meton_managed_creations WHERE source_marker=p_marker;
    SELECT * INTO STRICT u FROM public.users WHERE id=m.remote_user;
    SELECT coalesce(sum(l.remaining),0),coalesce(sum(l.held),0),coalesce(sum(l.refund_held),0),
        count(*) FILTER(WHERE e.kind='grant'),count(*) FILTER(WHERE e.kind='purchase'),
        count(*) FILTER(WHERE e.kind='grant' AND NOT EXISTS(SELECT FROM meton_ledger.registration_grants g
            WHERE g.event_id=e.event_id AND g.source_marker=p_marker AND g.eligibility=p_eligibility))
        INTO stock,held,refunds,gifts,purchases,other_grants
        FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=p_marker;
    SELECT count(*) INTO pending FROM meton_ledger.text_requests r WHERE r.source_marker=p_marker
        AND NOT EXISTS(SELECT FROM meton_ledger.text_send_decisions d WHERE d.request_id=r.request_id AND d.state='cancelled_unsent')
        AND NOT EXISTS(SELECT FROM meton_ledger.text_fee_endings f WHERE f.request_id=r.request_id);
    IF p_eligibility IS NULL OR p_eligibility='00000000-0000-0000-0000-000000000000'::uuid THEN state='scope_unknown';
    ELSIF purchases>0 OR refunds>0 OR u.frozen_balance<>0 OR u.total_recharged<>0
        OR EXISTS(SELECT FROM public.payment_orders o WHERE o.user_id=u.id)
        OR EXISTS(SELECT FROM public.promo_code_usages p WHERE p.user_id=u.id)
        OR EXISTS(SELECT FROM public.user_subscriptions s WHERE s.user_id=u.id)
        OR EXISTS(SELECT FROM public.user_affiliates a WHERE a.user_id=u.id OR a.inviter_id=u.id)
        OR EXISTS(SELECT FROM public.user_affiliate_ledger a WHERE a.user_id=u.id OR a.source_user_id=u.id)
        OR EXISTS(SELECT FROM public.redeem_codes r WHERE r.used_by=u.id AND r.type<>'meton_initial') THEN state='cash_review';
    ELSIF other_grants>0 OR stock<>u.balance OR EXISTS(SELECT FROM meton_ledger.accounts a WHERE a.source_marker=p_marker AND NOT EXISTS(
        SELECT FROM meton_ledger.events e WHERE e.source_marker=p_marker AND e.sequence=a.last_sequence AND e.balance_after=u.balance)) THEN state='source_review';
    ELSIF held>0 OR pending>0 OR meton_ledger.has_text_shortfall(p_marker)
        OR EXISTS(SELECT FROM meton_ledger.text_fee_disputes d JOIN meton_ledger.text_requests r USING(request_id) WHERE r.source_marker=p_marker)
        OR EXISTS(SELECT FROM meton_ledger.text_correction_decisions d JOIN meton_ledger.text_requests r USING(request_id)
            WHERE r.source_marker=p_marker AND NOT EXISTS(SELECT FROM meton_ledger.text_corrections c WHERE c.decision=d.decision)) THEN state='settlement_pending';
    ELSE state=CASE WHEN gifts=0 THEN 'empty' ELSE 'gift_only' END; END IF;
    RETURN jsonb_build_object('state',state,'balance',u.balance::numeric(20,8)::text,'gift',stock::numeric(20,8)::text,
        'held',held::numeric(20,8)::text,'refund_held',refunds::numeric(20,8)::text,'pending',pending);
END $$;

CREATE FUNCTION meton_ledger.find_gift_termination(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; t meton_ledger.gift_terminations%ROWTYPE; status jsonb;
BEGIN
    m=meton_ledger.gift_owner(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker);
    SELECT * INTO t FROM meton_ledger.gift_terminations WHERE source_marker=p_marker;
    IF FOUND AND ROW(t.environment,t.source,t.epoch,t.meton_user,t.account,t.creation,t.dispatch,t.remote_user,t.eligibility)
        IS DISTINCT FROM ROW(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_eligibility) THEN
        RAISE EXCEPTION 'gift termination target changed' USING ERRCODE='23505'; END IF;
    status=meton_ledger.gift_state(p_marker,p_eligibility);
    RETURN jsonb_build_object('environment',p_env,'source',p_source,'epoch',p_epoch,'user',p_user,'account',p_account,
        'creation',p_creation,'dispatch',p_dispatch,'remote_user',p_remote,'source_marker',p_marker,'eligibility',p_eligibility,
        'funds',status,'termination',CASE WHEN t.decision IS NULL THEN NULL ELSE to_jsonb(t) END,
        'retired',coalesce((SELECT sum(amount) FROM meton_ledger.gift_retirements WHERE decision=t.decision),0)::numeric(20,8)::text,
        'effects',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.effect) FROM meton_ledger.gift_retirements r WHERE r.decision=t.decision),'[]'::jsonb));
END $$;

CREATE FUNCTION meton_ledger.retire_gift_part(p_decision uuid,p_credit uuid,p_cause uuid,p_limit numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t meton_ledger.gift_terminations%ROWTYPE; l meton_ledger.lots%ROWTYPE; n numeric; native numeric; seq bigint; effect uuid:=gen_random_uuid();
BEGIN
    SELECT * INTO STRICT t FROM meton_ledger.gift_terminations WHERE decision=p_decision;
    IF EXISTS(SELECT FROM meton_ledger.gift_retirements r WHERE r.decision=p_decision AND r.credit_event=p_credit AND r.cause_event IS NOT DISTINCT FROM p_cause) THEN RETURN; END IF;
    SELECT v.* INTO l FROM meton_ledger.lots v JOIN meton_ledger.registration_grants g ON g.event_id=v.credit_event
        WHERE v.credit_event=p_credit AND NOT v.refundable AND g.source_marker=t.source_marker AND g.eligibility=t.eligibility FOR UPDATE OF v;
    IF NOT FOUND OR p_limit IS NULL OR p_limit<0 OR l.held<>0 OR l.refund_held<>0 THEN
        RAISE EXCEPTION 'unresolved original gift part' USING ERRCODE='55000'; END IF;
    n=least(l.remaining,p_limit);
    -- 零效果也留原因标记，避免稍后的新归还被旧事件重放错误认领。
    INSERT INTO meton_ledger.gift_retirements VALUES(effect,p_decision,p_credit,p_cause,n,CASE WHEN n>0 THEN effect ELSE NULL END);
    IF n=0 THEN RETURN; END IF;
    SELECT balance INTO STRICT native FROM public.users WHERE id=t.remote_user FOR UPDATE;
    UPDATE meton_ledger.lots SET remaining=remaining-n WHERE credit_event=p_credit;
    UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=t.source_marker RETURNING last_sequence INTO STRICT seq;
    IF native-n<>(SELECT coalesce(sum(v.remaining),0) FROM meton_ledger.lots v JOIN meton_ledger.events e ON e.event_id=v.credit_event WHERE e.source_marker=t.source_marker) THEN
        RAISE EXCEPTION 'gift retirement source mismatch' USING ERRCODE='23514'; END IF;
    INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
        VALUES(effect,t.environment,t.source,t.source_marker,effect,'gift_termination',effect,seq,-n,native,native-n);
END $$;

CREATE FUNCTION meton_ledger.gift_incoming_parts(p_event uuid) RETURNS TABLE(credit uuid,quantity numeric)
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT e.event_id,e.amount FROM meton_ledger.events e WHERE e.event_id=p_event AND e.kind='grant'
    UNION ALL
    SELECT s.credit_event,-sum(s.charged) FROM meton_ledger.events e JOIN meton_ledger.text_postings p ON p.journal_event=e.event_id
        JOIN meton_ledger.text_spend_splits s ON s.report_event=p.report_event
        WHERE e.event_id=p_event AND e.kind='text_revision' GROUP BY s.credit_event HAVING sum(s.charged)<0
    UNION ALL
    SELECT (line.value->>'credit_event')::uuid,(line.value->>'amount')::numeric FROM meton_ledger.events e
        JOIN meton_ledger.text_corrections c ON c.journal=e.event_id JOIN meton_ledger.text_correction_decisions d USING(decision)
        CROSS JOIN LATERAL jsonb_array_elements(d.sources) line(value) WHERE e.event_id=p_event AND e.kind='text_correction'
$$;
CREATE FUNCTION meton_ledger.retire_gift_incoming(p_event uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE e meton_ledger.events%ROWTYPE; t meton_ledger.gift_terminations%ROWTYPE; part record;
BEGIN
    SELECT * INTO STRICT e FROM meton_ledger.events WHERE event_id=p_event;
    IF e.amount<=0 OR e.kind NOT IN ('grant','text_revision','text_correction') THEN RETURN; END IF;
    SELECT * INTO t FROM meton_ledger.gift_terminations WHERE source_marker=e.source_marker;
    IF NOT FOUND OR e.sequence<=t.cutoff_sequence THEN RETURN; END IF;
    PERFORM meton_ledger.gift_owner(t.environment,t.source,t.epoch,t.meton_user,t.account,t.creation,t.dispatch,t.remote_user,t.source_marker);
    IF meton_ledger.gift_state(t.source_marker,t.eligibility)->>'state' NOT IN ('empty','gift_only') THEN RETURN; END IF;
    FOR part IN SELECT * FROM meton_ledger.gift_incoming_parts(e.event_id) LOOP
        IF EXISTS(SELECT FROM meton_ledger.registration_grants g WHERE g.event_id=part.credit AND g.source_marker=t.source_marker AND g.eligibility=t.eligibility) THEN
            PERFORM meton_ledger.retire_gift_part(t.decision,part.credit,e.event_id,part.quantity);
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION meton_ledger.terminate_gift(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,
    p_decision uuid,p_registration uuid,p_identity_event uuid,p_security bigint,p_identity_epoch bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; t meton_ledger.gift_terminations%ROWTYPE; status jsonb; part record;
BEGIN
    m=meton_ledger.gift_owner(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker);
    IF num_nulls(p_eligibility,p_decision,p_registration,p_identity_event,p_security,p_identity_epoch)>0 OR
        '00000000-0000-0000-0000-000000000000'::uuid IN (p_eligibility,p_decision,p_registration,p_identity_event) OR p_security<=0 OR p_identity_epoch<=0 THEN
        RAISE EXCEPTION 'explicit final identity decision required' USING ERRCODE='22023'; END IF;
    SELECT * INTO t FROM meton_ledger.gift_terminations WHERE source_marker=p_marker OR decision=p_decision;
    IF FOUND THEN
        IF ROW(t.environment,t.source,t.epoch,t.meton_user,t.account,t.creation,t.dispatch,t.remote_user,t.source_marker,t.eligibility,
            t.decision,t.registration,t.identity_event,t.security_version,t.identity_epoch)
            IS DISTINCT FROM ROW(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility,
            p_decision,p_registration,p_identity_event,p_security,p_identity_epoch) THEN RAISE EXCEPTION 'different final gift decision' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.find_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility);
    END IF;
    status=meton_ledger.gift_state(p_marker,p_eligibility);
    IF status->>'state' NOT IN ('empty','gift_only') THEN
        RETURN meton_ledger.find_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility); END IF;
    INSERT INTO meton_ledger.gift_terminations(decision,source_marker,environment,source,epoch,meton_user,account,creation,dispatch,remote_user,
        eligibility,registration,identity_event,security_version,identity_epoch,cutoff_sequence)
        VALUES(p_decision,p_marker,p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_eligibility,p_registration,p_identity_event,p_security,p_identity_epoch,
            coalesce((SELECT last_sequence FROM meton_ledger.accounts WHERE source_marker=p_marker),0));
    FOR part IN SELECT g.event_id,l.remaining FROM meton_ledger.registration_grants g JOIN meton_ledger.lots l ON l.credit_event=g.event_id
        WHERE g.source_marker=p_marker AND g.eligibility=p_eligibility LOOP
        PERFORM meton_ledger.retire_gift_part(p_decision,part.event_id,NULL,part.remaining);
    END LOOP;
    RETURN meton_ledger.find_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility);
END $$;

CREATE FUNCTION meton_ledger.reconcile_gift_termination(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_creation uuid,p_dispatch uuid,p_remote bigint,p_marker uuid,p_eligibility uuid,p_decision uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t meton_ledger.gift_terminations%ROWTYPE; e record;
BEGIN
    PERFORM meton_ledger.gift_owner(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker);
    SELECT * INTO t FROM meton_ledger.gift_terminations WHERE decision=p_decision AND source_marker=p_marker AND eligibility=p_eligibility AND epoch=p_epoch;
    IF NOT FOUND THEN RAISE EXCEPTION 'original gift termination missing' USING ERRCODE='55000'; END IF;
    FOR e IN SELECT event_id FROM meton_ledger.events WHERE source_marker=p_marker AND sequence>t.cutoff_sequence AND amount>0 ORDER BY sequence LOOP
        PERFORM meton_ledger.retire_gift_incoming(e.event_id);
    END LOOP;
    RETURN meton_ledger.find_gift_termination(p_env,p_source,p_epoch,p_user,p_account,p_creation,p_dispatch,p_remote,p_marker,p_eligibility);
END $$;

-- 提交期运行时，原赠送批次、纠正分配和正向流水均已齐备；核销失败会回滚整笔晚到资金。
CREATE FUNCTION meton_ledger.retire_closed_gift_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN PERFORM meton_ledger.retire_gift_incoming(NEW.event_id); RETURN NULL; END $$;
CREATE CONSTRAINT TRIGGER retire_closed_gift_event AFTER INSERT ON meton_ledger.events DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW WHEN(NEW.amount>0 AND NEW.kind IN ('grant','text_revision','text_correction')) EXECUTE FUNCTION meton_ledger.retire_closed_gift_event();

CREATE FUNCTION meton_ledger.gift_retirement_backed(p_effect uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.gift_retirements r JOIN meton_ledger.gift_terminations t USING(decision)
        JOIN meton_ledger.registration_grants g ON g.event_id=r.credit_event AND g.source_marker=t.source_marker AND g.eligibility=t.eligibility
        JOIN meton_ledger.events original ON original.event_id=g.event_id
        LEFT JOIN meton_ledger.events e ON e.event_id=r.journal
        WHERE r.effect=p_effect AND ((r.cause_event IS NULL AND original.sequence<=t.cutoff_sequence AND r.amount<=original.amount) OR
            EXISTS(SELECT FROM meton_ledger.events cause CROSS JOIN LATERAL meton_ledger.gift_incoming_parts(cause.event_id) part
                WHERE cause.event_id=r.cause_event AND cause.source_marker=t.source_marker AND cause.sequence>t.cutoff_sequence
                    AND cause.amount>0 AND part.credit=r.credit_event AND r.amount<=part.quantity))
        AND (r.amount=0 AND r.journal IS NULL OR r.amount>0 AND
            ROW(e.environment,e.source,e.source_marker,e.operation_id,e.kind,e.origin_ref,e.amount)
            IS NOT DISTINCT FROM ROW(t.environment,t.source,t.source_marker,r.effect,'gift_termination'::text,r.effect,-r.amount)))
$$;
CREATE FUNCTION meton_ledger.check_gift_retirement() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE expected numeric; actual numeric;
BEGIN
    IF NOT meton_ledger.gift_retirement_backed(NEW.effect) THEN RAISE EXCEPTION 'gift retirement lacks original journal' USING ERRCODE='23514'; END IF;
    SELECT e.amount-coalesce((SELECT sum(s.charged) FROM meton_ledger.text_spend_splits s WHERE s.credit_event=e.event_id),0)
        +coalesce((SELECT sum((line.value->>'amount')::numeric) FROM meton_ledger.text_corrections c JOIN meton_ledger.text_correction_decisions d USING(decision)
            CROSS JOIN LATERAL jsonb_array_elements(d.sources) line(value) WHERE (line.value->>'credit_event')::uuid=e.event_id),0)
        -coalesce((SELECT sum(r.amount) FROM meton_ledger.gift_retirements r WHERE r.credit_event=e.event_id),0),l.remaining
        INTO expected,actual FROM meton_ledger.events e JOIN meton_ledger.lots l ON l.credit_event=e.event_id WHERE e.event_id=NEW.credit_event;
    IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'gift retirement source conservation failed' USING ERRCODE='23514'; END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER original_retirement_journal AFTER INSERT ON meton_ledger.gift_retirements DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_gift_retirement();
DO $migration$
DECLARE body text:=pg_get_functiondef('meton_ledger.check_journal_backing()'::regprocedure);
    anchor text:='    ELSIF NEW.kind=''text_correction'' THEN';
    addition text:=$code$    ELSIF NEW.kind='gift_termination' THEN
        IF meton_ledger.gift_retirement_backed(NEW.event_id) THEN RETURN NULL; END IF;
$code$;
BEGIN
    IF length(body)-length(replace(body,anchor,''))<>length(anchor) THEN RAISE EXCEPTION 'correction journal signature changed'; END IF;
    EXECUTE replace(body,anchor,addition||anchor);
END $migration$;

CREATE FUNCTION meton_ledger.guard_terminated_gift_account() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid;
BEGIN
    IF TG_TABLE_NAME='text_send_decisions' THEN SELECT source_marker INTO marker FROM meton_ledger.text_requests WHERE request_id=NEW.request_id;
    ELSE marker=NEW.source_marker; END IF;
    -- 签发已持共享锁；继续共享即可阻止关闭的排他锁越过，升级会使不同会话互相等待。
    PERFORM 1 FROM public.users u JOIN public.meton_managed_creations m ON m.remote_user=u.id WHERE m.source_marker=marker FOR SHARE OF u;
    IF EXISTS(SELECT FROM meton_ledger.gift_terminations t WHERE t.source_marker=marker) THEN
        RAISE EXCEPTION 'original account terminated' USING ERRCODE='P5302'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER gift_closed_before_reserve BEFORE INSERT ON meton_ledger.text_requests FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_terminated_gift_account();
CREATE TRIGGER gift_closed_before_dispatch BEFORE INSERT ON meton_ledger.text_send_decisions FOR EACH ROW WHEN(NEW.state='dispatch_claimed') EXECUTE FUNCTION meton_ledger.guard_terminated_gift_account();
CREATE TRIGGER gift_closed_before_key BEFORE INSERT ON public.meton_managed_keys FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_terminated_gift_account();
CREATE FUNCTION meton_ledger.guard_terminated_gift_scope() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF EXISTS(SELECT FROM meton_ledger.gift_terminations t WHERE (t.source_marker=NEW.source_marker OR t.eligibility=NEW.eligibility)
        AND ROW(t.source_marker,t.eligibility) IS DISTINCT FROM ROW(NEW.source_marker,NEW.eligibility)) THEN
        RAISE EXCEPTION 'original gift qualification terminated' USING ERRCODE='23505'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER gift_closed_original_scope BEFORE INSERT ON meton_ledger.registration_grants FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_terminated_gift_scope();

-- 迁移不发布运行权限。部署方仅向独立读／写角色授予这三项公开函数，其余帮助函数不可调用。
REVOKE ALL ON FUNCTION meton_ledger.gift_owner(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid),
    meton_ledger.gift_state(uuid,uuid),meton_ledger.retire_gift_part(uuid,uuid,uuid,numeric),meton_ledger.gift_incoming_parts(uuid),meton_ledger.retire_gift_incoming(uuid),
    meton_ledger.retire_closed_gift_event(),meton_ledger.gift_retirement_backed(uuid),meton_ledger.check_gift_retirement(),
    meton_ledger.guard_terminated_gift_account(),meton_ledger.guard_terminated_gift_scope(),
    meton_ledger.find_gift_termination(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid),
    meton_ledger.terminate_gift(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,uuid,bigint,bigint),
    meton_ledger.reconcile_gift_termination(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid) FROM PUBLIC;
