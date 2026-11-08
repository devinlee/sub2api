-- 已核实的历史批次成为来源期初，原生余额保持原值。启用和随后消费仍各自是原账号上的独立事务。
CREATE TABLE meton_ledger.legacy_source_openings (
    cutoff uuid PRIMARY KEY REFERENCES meton_ledger.legacy_balance_fences,
    operation uuid NOT NULL UNIQUE CHECK(operation<>'00000000-0000-0000-0000-000000000000'),
    review uuid NOT NULL UNIQUE REFERENCES meton_ledger.legacy_source_reviews,
    source_marker uuid NOT NULL UNIQUE REFERENCES public.meton_managed_creations(source_marker),
    activation_epoch bigint NOT NULL CHECK(activation_epoch>0), evidence_ref text NOT NULL CHECK(evidence_ref~'^[0-9a-f]{64}$'),
    initial_balance numeric(20,8) NOT NULL CHECK(initial_balance>=0), source_count integer NOT NULL CHECK(source_count>=0),
    posting_xid xid8 NOT NULL DEFAULT pg_current_xact_id(), activated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE meton_ledger.legacy_opening_events (
    event_id uuid PRIMARY KEY REFERENCES meton_ledger.events DEFERRABLE INITIALLY DEFERRED,
    cutoff uuid NOT NULL REFERENCES meton_ledger.legacy_source_openings, review uuid NOT NULL, ordinal integer NOT NULL,
    FOREIGN KEY(review,ordinal) REFERENCES meton_ledger.legacy_source_components, UNIQUE(cutoff,ordinal)
);
DO $immutable$
DECLARE item text;
BEGIN
    FOREACH item IN ARRAY ARRAY['legacy_source_openings','legacy_opening_events'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',item);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',item);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',item);
    END LOOP;
END $immutable$;
-- 启用依赖的完成约束和原事实保护必须实际存在；仅有迁移号或启用记录不能放行凭据与资金操作。
CREATE FUNCTION meton_ledger.legacy_opening_guards_ready() RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT EXISTS(SELECT FROM (
        SELECT ('meton_ledger.'||n)::regclass tbl,'immutable_fact'::text name,'meton_ledger.keep_event()'::text proc,27 events,false deferred
        FROM unnest(ARRAY['legacy_source_openings','legacy_opening_events','legacy_source_reviews','legacy_source_components',
            'legacy_qualifications','legacy_qualification_facts']) n
        UNION ALL VALUES ('public.api_keys'::regclass,'meton_legacy_managed_new_key','meton_ledger.check_legacy_new_key()',5,true),
            ('meton_ledger.legacy_source_openings'::regclass,'complete_legacy_opening','meton_ledger.check_legacy_opening()',5,true),
            ('meton_ledger.events'::regclass,'apply_credit','meton_ledger.apply_credit()',5,false)
    ) expected WHERE NOT EXISTS(SELECT FROM pg_trigger t WHERE t.tgrelid=expected.tbl AND t.tgname=expected.name
        AND t.tgfoid=to_regprocedure(expected.proc) AND t.tgenabled=CASE WHEN expected.name='apply_credit' THEN 'O'::"char" ELSE 'A'::"char" END
        AND t.tgtype=expected.events AND t.tgdeferrable=expected.deferred AND t.tginitdeferred=expected.deferred
        AND t.tgqual IS NULL AND t.tgnargs=0 AND t.tgattr=''::int2vector))
$$;
CREATE FUNCTION meton_ledger.legacy_source_active(p_marker uuid,p_epoch bigint) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.legacy_source_openings a JOIN public.meton_managed_creations m USING(source_marker)
        JOIN public.users u ON (u.id,u.meton_legacy_balance_fence)=(m.remote_user,a.cutoff)
        JOIN public.meton_managed_fence f ON (f.environment,f.source,f.epoch)=(m.environment,m.source,m.epoch)
        WHERE a.source_marker=p_marker AND a.activation_epoch=p_epoch AND f.singleton AND f.enabled AND f.epoch=p_epoch
            AND meton_ledger.legacy_balance_guard_ready() AND meton_ledger.legacy_cash_guards_ready() AND meton_ledger.legacy_activity_guards_ready()
            AND meton_ledger.legacy_opening_guards_ready()
            AND NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin')
$$;

-- 新 Key 必须仍由 S1 原签发事务生成完整原凭证；普通原生插 Key 不能借来源启用取得调用资格。
CREATE FUNCTION meton_ledger.check_legacy_new_key() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE source_id uuid; current_epoch bigint;
BEGIN
    SELECT m.source_marker,m.epoch INTO source_id,current_epoch FROM public.users u JOIN public.meton_managed_creations m ON m.remote_user=u.id
        WHERE u.id=NEW.user_id AND u.meton_legacy_balance_fence IS NOT NULL;
    IF NOT FOUND THEN RETURN NEW; END IF;
    IF NOT meton_ledger.legacy_source_active(source_id,current_epoch) OR NOT EXISTS(
        SELECT FROM public.meton_managed_keys k JOIN meton_ledger.legacy_source_openings a ON a.source_marker=k.source_marker
        JOIN public.meton_managed_creations m ON m.source_marker=k.source_marker
        WHERE k.remote_key=NEW.id AND k.source_marker=source_id AND m.remote_user=NEW.user_id AND k.created_at=NEW.created_at
            AND k.expires_at=NEW.expires_at AND k.created_at>=a.activated_at AND k.material_sha256=encode(sha256(convert_to(NEW.key,'UTF8')),'hex')
            AND NEW.status='active' AND NEW.deleted_at IS NULL AND NEW.expires_at<=NEW.created_at+interval '24 hours'
            AND (k.claim->'origin'->>'epoch')::bigint=current_epoch
            AND NOT EXISTS(SELECT FROM public.meton_managed_session_closures c WHERE c.source_marker=source_id AND c.session_id=k.session_id)) THEN
        RAISE EXCEPTION 'new historical key requires original managed issuance' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER meton_legacy_managed_new_key AFTER INSERT ON public.api_keys DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_legacy_new_key();
ALTER TABLE public.api_keys ENABLE ALWAYS TRIGGER meton_legacy_managed_new_key;

DO $extend$
DECLARE definition text; needle text;
BEGIN
    definition:=pg_get_functiondef('meton_ledger.guard_legacy_activity()'::regprocedure);
    needle:='PERFORM meton_ledger.check_legacy_native_users(owners);';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected activity guard'; END IF;
    EXECUTE replace(definition,needle,$newkey$IF TG_TABLE_NAME='api_keys' AND TG_OP='INSERT' THEN
        IF EXISTS(SELECT FROM public.meton_managed_creations m WHERE m.remote_user=NEW.user_id
            AND meton_ledger.legacy_source_active(m.source_marker,m.epoch)) THEN RETURN NEW; END IF;
    END IF;
    $newkey$||needle);

    definition:=pg_get_functiondef('meton_ledger.guard_legacy_native_balance()'::regprocedure);
    needle:='-- 标记在旧进程要更新的同一行。';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected historical balance guard'; END IF;
    EXECUTE replace(definition,needle,$posting$IF pg_trigger_depth()>1 AND
        (to_jsonb(NEW)-'balance')=(to_jsonb(OLD)-'balance') AND EXISTS(
        SELECT FROM meton_ledger.events e JOIN public.meton_managed_creations m USING(source_marker)
        WHERE m.remote_user=OLD.id AND meton_ledger.legacy_source_active(m.source_marker,m.epoch)
            AND e.posting_xid=pg_current_xact_id() AND e.balance_before=OLD.balance AND e.balance_after=NEW.balance
            AND NOT EXISTS(SELECT FROM meton_ledger.legacy_opening_events x WHERE x.event_id=e.event_id)) THEN RETURN NEW; END IF;
    $posting$||needle);

    definition:=pg_get_functiondef('meton_ledger.apply_credit()'::regprocedure);
    needle:='UPDATE public.users u SET balance=NEW.balance_after';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected original posting'; END IF;
    EXECUTE replace(definition,needle,$opening$IF EXISTS(SELECT FROM meton_ledger.legacy_opening_events x WHERE x.event_id=NEW.event_id) THEN
        IF NOT EXISTS(SELECT FROM meton_ledger.legacy_opening_events x JOIN meton_ledger.legacy_source_openings a USING(cutoff)
            JOIN meton_ledger.legacy_source_components c ON (c.review,c.ordinal)=(x.review,x.ordinal)
            JOIN public.meton_managed_creations m ON m.source_marker=a.source_marker JOIN public.users u ON u.id=m.remote_user
            WHERE x.event_id=NEW.event_id AND a.review=x.review AND a.source_marker=NEW.source_marker AND a.posting_xid=pg_current_xact_id()
                AND NEW.posting_xid=a.posting_xid AND NEW.kind=c.kind AND NEW.origin_ref=c.origin AND NEW.amount=c.remaining
                AND u.balance=a.initial_balance AND u.frozen_balance=0 AND u.meton_legacy_balance_fence=a.cutoff) THEN
            RAISE EXCEPTION 'original opening proof mismatch' USING ERRCODE='23514'; END IF;
        INSERT INTO meton_ledger.outbox(event_id) VALUES(NEW.event_id);
        RETURN NEW;
    END IF;
    $opening$||needle);

    definition:=pg_get_functiondef('meton_ledger.lock_text_owner(text,text,bigint,uuid,uuid,uuid)'::regprocedure);
    needle:='JOIN public.meton_s1_funds_births b ON b.operation=m.operation AND b.remote_user=u.id';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected text origin'; END IF;
    definition:=replace(definition,needle,'LEFT JOIN public.meton_s1_funds_births b ON b.operation=m.operation AND b.remote_user=u.id');
    needle:='AND u.role=''user''';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected text ownership'; END IF;
    EXECUTE replace(definition,needle,'AND (b.remote_user IS NOT NULL OR meton_ledger.legacy_source_active(m.source_marker,m.epoch)) '||needle);

    -- 原截点继续返回原数值；消费后按当前来源流水核对当前余额，不把已消费后的变化解释成历史证据丢失。
    definition:=pg_get_functiondef('meton_ledger.find_legacy_balance_fence(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid)'::regprocedure);
    needle:='(u.balance,u.frozen_balance,u.total_recharged)=(b.cutoff_balance,b.cutoff_frozen,b.cutoff_recharged)';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected original cutoff lookup'; END IF;
    definition:=replace(definition,needle,'('||needle||$current$ OR (meton_ledger.legacy_source_active(m.source_marker,m.epoch)
        AND u.frozen_balance=0 AND u.total_recharged=b.cutoff_recharged
        AND u.balance=(SELECT coalesce(sum(l.remaining),0) FROM meton_ledger.events e JOIN meton_ledger.lots l ON l.credit_event=e.event_id WHERE e.source_marker=m.source_marker)
        AND u.balance=coalesce((SELECT e.balance_after FROM meton_ledger.events e JOIN meton_ledger.accounts a
            ON (a.source_marker,a.last_sequence)=(e.source_marker,e.sequence) WHERE a.source_marker=m.source_marker),0)))$current$);
    EXECUTE replace(definition,'''state'',''balance_frozen_needs_reconciliation''',
        '''state'',CASE WHEN meton_ledger.legacy_source_active(m.source_marker,m.epoch) THEN ''source_opened'' ELSE ''balance_frozen_needs_reconciliation'' END');

    definition:=pg_get_functiondef('meton_ledger.record_legacy_source_review(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text)'::regprocedure);
    needle:='SELECT * INTO prior FROM meton_ledger.legacy_source_reviews';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected source review'; END IF;
    EXECUTE replace(definition,needle,$sealed$IF EXISTS(SELECT FROM meton_ledger.legacy_source_openings WHERE cutoff=p_cutoff) THEN
        RAISE EXCEPTION 'original source opening already sealed' USING ERRCODE='23505'; END IF;
    $sealed$||needle);
END $extend$;

CREATE FUNCTION meton_ledger.check_legacy_opening() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NEW.posting_xid<>pg_current_xact_id() OR NOT EXISTS(SELECT FROM public.meton_managed_creations m JOIN public.users u ON u.id=m.remote_user
        WHERE m.source_marker=NEW.source_marker AND u.meton_legacy_balance_fence=NEW.cutoff AND u.balance=NEW.initial_balance AND u.frozen_balance=0)
        OR NEW.source_count<>(SELECT count(*) FROM meton_ledger.legacy_opening_events WHERE cutoff=NEW.cutoff)
        OR NEW.source_count<>(SELECT count(*) FROM meton_ledger.legacy_source_components WHERE review=NEW.review AND remaining>0)
        OR (NEW.source_count>0 AND NOT EXISTS(SELECT FROM meton_ledger.accounts a JOIN meton_ledger.events e
            ON (a.source_marker,a.last_sequence)=(e.source_marker,e.sequence) WHERE a.source_marker=NEW.source_marker
                AND a.last_sequence=NEW.source_count AND e.balance_after=NEW.initial_balance))
        OR (NEW.source_count=0 AND (NEW.initial_balance<>0 OR EXISTS(SELECT FROM meton_ledger.accounts WHERE source_marker=NEW.source_marker)))
        OR NEW.initial_balance<>(SELECT coalesce(sum(l.remaining),0) FROM meton_ledger.legacy_opening_events x JOIN meton_ledger.lots l ON l.credit_event=x.event_id WHERE x.cutoff=NEW.cutoff)
        OR EXISTS(SELECT FROM meton_ledger.legacy_opening_events x LEFT JOIN meton_ledger.events e ON e.event_id=x.event_id
            JOIN meton_ledger.legacy_source_components c ON (c.review,c.ordinal)=(x.review,x.ordinal)
            LEFT JOIN meton_ledger.lots l ON l.credit_event=e.event_id LEFT JOIN meton_ledger.outbox o ON o.event_id=e.event_id
            WHERE x.cutoff=NEW.cutoff AND (x.review<>NEW.review OR e.event_id IS NULL OR l.credit_event IS NULL OR o.event_id IS NULL
                OR e.source_marker<>NEW.source_marker OR e.posting_xid<>NEW.posting_xid OR e.amount<>c.remaining OR l.remaining<>c.remaining
                OR l.held<>0 OR l.refund_held<>0 OR e.kind<>c.kind OR e.origin_ref<>c.origin
                OR (l.rule_version,l.denomination,l.face_value,l.conversion_rate,l.refundable)
                    IS DISTINCT FROM (c.rule_version,c.denomination,c.face_value,c.conversion_rate,c.kind='purchase'))) THEN
        RAISE EXCEPTION 'incomplete original opening' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER complete_legacy_opening AFTER INSERT ON meton_ledger.legacy_source_openings DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_legacy_opening();
ALTER TABLE meton_ledger.legacy_source_openings ENABLE ALWAYS TRIGGER complete_legacy_opening;

CREATE FUNCTION meton_ledger.activate_legacy_source(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid,p_operation uuid,p_review uuid,p_evidence text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_ledger.legacy_source_reviews%ROWTYPE; a meton_ledger.legacy_source_openings%ROWTYPE; h jsonb; c record;
    ref uuid; business_ref uuid; running numeric:=0; seq bigint:=0; total_sources integer;
BEGIN
    IF NOT EXISTS(SELECT FROM meton_ledger.legacy_balance_fences WHERE cutoff=p_cutoff AND source_marker=p_marker AND remote_user=p_remote) THEN
        RAISE EXCEPTION 'original cutoff required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.freeze_legacy_balance(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff);
    IF NOT meton_ledger.legacy_opening_guards_ready() THEN RAISE EXCEPTION 'source opening protections unavailable' USING ERRCODE='55000'; END IF;
    IF p_operation IS NULL OR p_operation='00000000-0000-0000-0000-000000000000' OR p_review IS NULL
        OR p_evidence IS NULL OR p_evidence!~'^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'activation evidence required' USING ERRCODE='22023'; END IF;
    SELECT * INTO a FROM meton_ledger.legacy_source_openings WHERE cutoff=p_cutoff;
    IF FOUND THEN
        IF (a.operation,a.review,a.evidence_ref,a.activation_epoch) IS DISTINCT FROM (p_operation,p_review,p_evidence,p_epoch) THEN
            RAISE EXCEPTION 'original opening conflict' USING ERRCODE='23505'; END IF;
        RETURN a.operation;
    END IF;
    h:=meton_ledger.find_legacy_activity(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff);
    SELECT * INTO r FROM meton_ledger.legacy_source_reviews WHERE cutoff=p_cutoff ORDER BY revision DESC LIMIT 1;
    IF r.operation IS NULL OR r.operation IS DISTINCT FROM p_review OR r.unknown_amount<>0 OR r.original_debt<>0 OR r.original_precharge<>0
        OR h->>'cash_state' IS DISTINCT FROM 'cash_evidence_frozen' OR h->>'activity_state' IS DISTINCT FROM 'activity_evidence_frozen'
        OR r.known_amount<>(h->>'balance')::numeric OR EXISTS(SELECT FROM meton_ledger.accounts WHERE source_marker=p_marker) THEN
        RAISE EXCEPTION 'original sources require reconciliation' USING ERRCODE='55000'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.legacy_cash_facts WHERE cutoff=p_cutoff AND kind='order'
        AND proof->>'state' NOT IN ('COMPLETED','EXPIRED','CANCELLED','FAILED')) OR
        EXISTS(SELECT FROM meton_ledger.legacy_activity_facts WHERE cutoff=p_cutoff AND
            (kind='unassigned_idempotency' OR (kind='batch_image_jobs' AND (coalesce(proof->>'status','') NOT IN ('completed','failed','cancelled') OR proof->>'settled_at' IS NULL))
             OR (kind='batch_image_items' AND coalesce(proof->>'status','') NOT IN ('succeeded','completed','failed','cancelled'))
             OR (kind='user_subscriptions' AND proof->>'status'='active' AND (proof->>'expires_at')::timestamptz>clock_timestamp()))) THEN
        RAISE EXCEPTION 'old unsettled activity must keep its original disposition' USING ERRCODE='55000'; END IF;
    -- 调用方复用 S1 的会话关闭和外部旧写者处置，提交其审计引用；已知旧会话必须有实际关闭凭证。
    IF EXISTS(SELECT FROM public.api_keys WHERE user_id=p_remote AND status<>'inactive') OR EXISTS(
        SELECT FROM meton_ledger.legacy_activity_facts f JOIN public.meton_managed_keys k ON k.remote_key=(f.proof->>'id')::bigint
        WHERE f.cutoff=p_cutoff AND f.kind='api_keys' AND NOT EXISTS(SELECT FROM public.meton_managed_session_closures s
            WHERE s.source_marker=p_marker AND s.session_id=k.session_id)) THEN
        RAISE EXCEPTION 'old session closure evidence incomplete' USING ERRCODE='55000'; END IF;
    SELECT count(*) INTO total_sources FROM meton_ledger.legacy_source_components WHERE review=p_review AND remaining>0;
    INSERT INTO meton_ledger.legacy_source_openings(cutoff,operation,review,source_marker,activation_epoch,evidence_ref,initial_balance,source_count)
        VALUES(p_cutoff,p_operation,p_review,p_marker,p_epoch,p_evidence,r.known_amount,total_sources);
    IF total_sources>0 THEN INSERT INTO meton_ledger.accounts VALUES(p_marker,r.unit,total_sources); END IF;
    FOR c IN SELECT * FROM meton_ledger.legacy_source_components WHERE review=p_review AND remaining>0 ORDER BY credited_at,native_id,kind,origin LOOP
        seq:=seq+1; ref:=gen_random_uuid();
        business_ref:=md5('meton-historical-opening:'||p_cutoff::text||':'||c.kind||':'||c.origin::text)::uuid;
        INSERT INTO meton_ledger.legacy_opening_events VALUES(ref,p_cutoff,p_review,c.ordinal);
        INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
            VALUES(ref,p_env,p_source,p_marker,business_ref,c.kind,c.origin,seq,c.remaining,running,running+c.remaining);
        INSERT INTO meton_ledger.lots(credit_event,rule_version,denomination,face_value,conversion_rate,refundable,remaining)
            VALUES(ref,c.rule_version,c.denomination,c.face_value,c.conversion_rate,c.kind='purchase',c.remaining);
        running:=running+c.remaining;
    END LOOP;
    RETURN p_operation;
END $$;

CREATE FUNCTION meton_ledger.find_legacy_source_opening(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid,p_operation uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('state','source_opened','operation',a.operation,'cutoff',a.cutoff,'review',a.review,'source_marker',a.source_marker,
        'activation_epoch',a.activation_epoch,'evidence_ref',a.evidence_ref,'initial_balance',a.initial_balance::text,'source_count',a.source_count,
        'sources',(SELECT coalesce(jsonb_agg(jsonb_build_object('event_id',e.event_id,'kind',e.kind,'origin',e.origin_ref,
            'sequence',e.sequence,'opening_amount',e.amount::text,'original_amount',c.original_amount::text,'face_value',c.face_value::text,
            'conversion_rate',c.conversion_rate::text,'denomination',c.denomination,'rule',c.rule_version,'credited_at',c.credited_at) ORDER BY e.sequence),'[]'::jsonb)
            FROM meton_ledger.legacy_opening_events x JOIN meton_ledger.events e ON e.event_id=x.event_id
            JOIN meton_ledger.legacy_source_components c ON (c.review,c.ordinal)=(x.review,x.ordinal) WHERE x.cutoff=a.cutoff))
    FROM meton_ledger.legacy_source_openings a WHERE a.cutoff=p_cutoff AND a.source_marker=p_marker AND a.operation=p_operation
        AND meton_ledger.legacy_source_active(p_marker,p_epoch)
        AND meton_ledger.find_legacy_balance_fence(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff) IS NOT NULL
$$;

-- 对账以单独期初加后续资金净额计算；重建批次的正数量不得再次作为本期赠送或充值加总。
CREATE VIEW meton_ledger.source_period_events AS
    SELECT e.*,x.cutoff AS opening_cutoff,CASE WHEN x.event_id IS NULL THEN e.amount ELSE 0::numeric END AS period_change
    FROM meton_ledger.events e LEFT JOIN meton_ledger.legacy_opening_events x ON x.event_id=e.event_id;
REVOKE ALL ON meton_ledger.source_period_events FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.legacy_source_active(uuid,bigint),meton_ledger.check_legacy_new_key(),meton_ledger.check_legacy_opening(),
    meton_ledger.legacy_opening_guards_ready(),meton_ledger.activate_legacy_source(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,text),
    meton_ledger.find_legacy_source_opening(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid) FROM PUBLIC;
