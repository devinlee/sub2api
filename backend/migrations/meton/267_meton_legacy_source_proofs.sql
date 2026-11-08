-- 历史来源分类只引用已经冻结的原凭证；分类不是赠送或充值，也不改变原生余额和预扣。
CREATE TABLE meton_ledger.legacy_source_reviews (
    operation uuid PRIMARY KEY CHECK(operation<>'00000000-0000-0000-0000-000000000000'),
    cutoff uuid NOT NULL REFERENCES meton_ledger.legacy_activity_manifests,
    previous uuid REFERENCES meton_ledger.legacy_source_reviews, revision bigint NOT NULL CHECK(revision>0),
    unit text NOT NULL, evidence_ref text NOT NULL, request jsonb NOT NULL,
    known_amount numeric(20,8) NOT NULL CHECK(known_amount>=0), unknown_amount numeric(20,8) NOT NULL CHECK(unknown_amount>=0),
    original_debt numeric(20,8) NOT NULL CHECK(original_debt>=0), original_precharge numeric NOT NULL,
    reviewer name NOT NULL DEFAULT session_user, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(cutoff,revision), UNIQUE(previous)
);
CREATE TABLE meton_ledger.legacy_source_components (
    review uuid NOT NULL REFERENCES meton_ledger.legacy_source_reviews,
    ordinal integer NOT NULL CHECK(ordinal>0), kind text NOT NULL CHECK(kind IN ('grant','purchase')),
    origin uuid NOT NULL CHECK(origin<>'00000000-0000-0000-0000-000000000000'),
    native_kind text NOT NULL, native_id bigint NOT NULL CHECK(native_id>0), evidence_ref text NOT NULL,
    rule_version text NOT NULL, denomination text NOT NULL, face_value numeric(20,8) NOT NULL CHECK(face_value>0),
    conversion_rate numeric(20,8) NOT NULL CHECK(conversion_rate>0), original_amount numeric(20,8) NOT NULL CHECK(original_amount>0),
    remaining numeric(20,8) NOT NULL CHECK(remaining>=0 AND remaining<=original_amount), credited_at timestamptz NOT NULL,
    PRIMARY KEY(review,ordinal), UNIQUE(review,kind,origin), UNIQUE(review,native_kind,native_id),
    CHECK(original_amount=face_value*conversion_rate), CHECK((kind='grant' AND native_kind='redemption') OR (kind='purchase' AND native_kind='order'))
);
-- 领取和终止的外部原事实独立留存。来源归零、重分类、原生码清理或以后换账号均不能抹去资格身份。
CREATE TABLE meton_ledger.legacy_qualifications (
    environment text NOT NULL, source text NOT NULL, eligibility uuid NOT NULL CHECK(eligibility<>'00000000-0000-0000-0000-000000000000'),
    source_marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker), meton_user uuid NOT NULL,
    registration uuid NOT NULL CHECK(registration<>'00000000-0000-0000-0000-000000000000'),
    PRIMARY KEY(environment,source,eligibility)
);
CREATE TABLE meton_ledger.legacy_qualification_facts (
    environment text NOT NULL, source text NOT NULL, eligibility uuid NOT NULL, state text NOT NULL CHECK(state IN ('received','terminated')),
    evidence_ref text NOT NULL, review uuid NOT NULL REFERENCES meton_ledger.legacy_source_reviews,
    PRIMARY KEY(environment,source,eligibility,state),
    FOREIGN KEY(environment,source,eligibility) REFERENCES meton_ledger.legacy_qualifications
);
DO $immutable$
DECLARE item text;
BEGIN
    FOREACH item IN ARRAY ARRAY['legacy_source_reviews','legacy_source_components','legacy_qualifications','legacy_qualification_facts'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',item);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',item);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',item);
    END LOOP;
END $immutable$;

CREATE FUNCTION meton_ledger.record_legacy_source_review(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid,p_operation uuid,p_previous uuid,p_unit text,p_evidence text,p_lots jsonb,p_claims jsonb,p_unknown text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE header jsonb; body jsonb; original meton_ledger.legacy_source_reviews%ROWTYPE; prior meton_ledger.legacy_source_reviews%ROWTYPE;
    item jsonb; fact jsonb; redemption jsonb; prior_item jsonb;
    count_lots integer:=0; count_claims integer:=0; total numeric:=0; qty numeric; left_qty numeric; face numeric; rate numeric;
    v_native_id bigint; origin uuid; v_eligibility uuid; registered uuid; credit_at timestamptz;
    pattern constant text:='^(0|[1-9][0-9]{0,11})[.][0-9]{8}$';
BEGIN
    -- 复用切换的受限身份、当前代次、实际保护和逐账号行锁；禁止本操作顺带新建一个截点。
    IF NOT EXISTS(SELECT FROM meton_ledger.legacy_balance_fences WHERE cutoff=p_cutoff AND source_marker=p_marker AND remote_user=p_remote) THEN
        RAISE EXCEPTION 'original cutoff required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.freeze_legacy_balance(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff);
    header:=meton_ledger.find_legacy_activity(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff);
    IF header->>'activity_state' IS DISTINCT FROM 'activity_evidence_frozen' OR header->>'cash_state' IS DISTINCT FROM 'cash_evidence_frozen' THEN
        RAISE EXCEPTION 'original evidence unavailable' USING ERRCODE='55000'; END IF;
    IF p_operation IS NULL OR p_operation='00000000-0000-0000-0000-000000000000' OR p_operation=p_previous
        OR p_unit IS NULL OR p_unit!~'^[A-Za-z0-9_.-]{1,120}$' OR p_evidence IS NULL OR p_evidence!~'^[0-9a-f]{64}$'
        OR p_unknown IS NULL OR p_unknown!~pattern OR jsonb_typeof(p_lots) IS DISTINCT FROM 'array' OR jsonb_typeof(p_claims) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'invalid original review' USING ERRCODE='22023'; END IF;
    IF jsonb_array_length(p_lots)>1000 OR jsonb_array_length(p_claims)>1000 THEN RAISE EXCEPTION 'review page too large' USING ERRCODE='22023'; END IF;
    body:=jsonb_build_object('unit',p_unit,'evidence',p_evidence,'lots',p_lots,'claims',p_claims,'unknown',p_unknown);
    SELECT * INTO original FROM meton_ledger.legacy_source_reviews WHERE operation=p_operation;
    IF FOUND THEN
        IF original.cutoff<>p_cutoff OR original.previous IS DISTINCT FROM p_previous OR original.request<>body THEN
            RAISE EXCEPTION 'original review conflict' USING ERRCODE='23505'; END IF;
        RETURN original.operation;
    END IF;
    SELECT * INTO prior FROM meton_ledger.legacy_source_reviews WHERE cutoff=p_cutoff ORDER BY revision DESC LIMIT 1;
    IF prior.operation IS DISTINCT FROM p_previous OR (prior.operation IS NOT NULL AND prior.unit<>p_unit) THEN
        RAISE EXCEPTION 'review predecessor changed' USING ERRCODE='23505'; END IF;
    -- 后续证据只补充未知来源；已经确认的原批次和资格不得在新版本中被静默替换或删除。
    IF prior.operation IS NOT NULL THEN
        FOR prior_item IN SELECT value FROM jsonb_array_elements(prior.request->'lots') LOOP
            IF NOT p_lots @> jsonb_build_array(prior_item) THEN RAISE EXCEPTION 'prior source proof removed' USING ERRCODE='23505'; END IF;
        END LOOP;
        FOR prior_item IN SELECT value FROM jsonb_array_elements(prior.request->'claims') LOOP
            IF NOT p_claims @> jsonb_build_array(prior_item) THEN RAISE EXCEPTION 'prior qualification removed' USING ERRCODE='23505'; END IF;
        END LOOP;
    END IF;
    INSERT INTO meton_ledger.legacy_source_reviews(operation,cutoff,previous,revision,unit,evidence_ref,request,known_amount,unknown_amount,original_debt,original_precharge)
        VALUES(p_operation,p_cutoff,p_previous,coalesce(prior.revision,0)+1,p_unit,p_evidence,body,
               coalesce((SELECT sum((value->>'remaining')::numeric) FROM jsonb_array_elements(p_lots)),0),p_unknown::numeric,
               greatest(0,-(header->>'balance')::numeric),(header->>'frozen')::numeric);
    FOR item IN SELECT value FROM jsonb_array_elements(p_claims) LOOP
        count_claims:=count_claims+1;
        IF jsonb_typeof(item)<>'object' OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(item) k)
            IS DISTINCT FROM ARRAY['eligibility','evidence','registration','state'] OR
            EXISTS(SELECT FROM jsonb_each(item) v WHERE jsonb_typeof(v.value)<>'string') OR item->>'evidence'!~'^[0-9a-f]{64}$'
            OR item->>'state' NOT IN ('received','terminated') THEN RAISE EXCEPTION 'invalid qualification proof' USING ERRCODE='22023'; END IF;
        v_eligibility:=(item->>'eligibility')::uuid; registered:=(item->>'registration')::uuid;
        INSERT INTO meton_ledger.legacy_qualifications VALUES(p_env,p_source,v_eligibility,p_marker,p_user,registered) ON CONFLICT DO NOTHING;
        IF NOT EXISTS(SELECT FROM meton_ledger.legacy_qualifications q WHERE (q.environment,q.source,q.eligibility,q.source_marker,q.meton_user,q.registration)
            =(p_env,p_source,v_eligibility,p_marker,p_user,registered)) THEN RAISE EXCEPTION 'qualification belongs to another origin' USING ERRCODE='23505'; END IF;
        INSERT INTO meton_ledger.legacy_qualification_facts VALUES(p_env,p_source,v_eligibility,item->>'state',item->>'evidence',p_operation) ON CONFLICT DO NOTHING;
        IF NOT EXISTS(SELECT FROM meton_ledger.legacy_qualification_facts q WHERE (q.environment,q.source,q.eligibility,q.state,q.evidence_ref)
            =(p_env,p_source,v_eligibility,item->>'state',item->>'evidence')) THEN RAISE EXCEPTION 'qualification evidence conflict' USING ERRCODE='23505'; END IF;
    END LOOP;
    IF count_claims<>(SELECT count(DISTINCT (value->>'eligibility',value->>'state')) FROM jsonb_array_elements(p_claims)) THEN
        RAISE EXCEPTION 'duplicate qualification proof' USING ERRCODE='23505'; END IF;
    FOR item IN SELECT value FROM jsonb_array_elements(p_lots) LOOP
        count_lots:=count_lots+1;
        IF jsonb_typeof(item)<>'object' OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(item) k) IS DISTINCT FROM
            ARRAY['denomination','evidence','face','kind','nativeId','origin','original','rate','remaining','rule'] OR
            EXISTS(SELECT FROM jsonb_each(item) v WHERE jsonb_typeof(v.value)<>'string') OR
            item->>'evidence'!~'^[0-9a-f]{64}$' OR item->>'kind' NOT IN ('grant','purchase') OR item->>'denomination'!~'^[A-Z]{3}$' OR
            item->>'rule'!~'^[A-Za-z0-9_.-]{1,120}$' OR item->>'nativeId'!~'^[1-9][0-9]{0,17}$' OR
            item->>'face'!~pattern OR item->>'rate'!~pattern OR item->>'original'!~pattern OR item->>'remaining'!~pattern THEN
            RAISE EXCEPTION 'invalid source proof' USING ERRCODE='22023'; END IF;
        origin:=(item->>'origin')::uuid; v_native_id:=(item->>'nativeId')::bigint;
        face:=(item->>'face')::numeric; rate:=(item->>'rate')::numeric; qty:=(item->>'original')::numeric; left_qty:=(item->>'remaining')::numeric;
        IF face<=0 OR rate<=0 OR qty<=0 OR face*rate<>qty OR left_qty>qty THEN RAISE EXCEPTION 'original source conversion mismatch' USING ERRCODE='22023'; END IF;
        IF item->>'kind'='grant' THEN
            SELECT proof INTO fact FROM meton_ledger.legacy_cash_facts WHERE cutoff=p_cutoff AND kind='redemption' AND native_id=v_native_id;
            IF fact IS NULL OR fact->>'state' IS DISTINCT FROM 'used' OR coalesce(fact->>'type','') NOT IN ('balance','meton_initial') OR (fact->>'value')::numeric IS DISTINCT FROM qty OR
                fact->>'code_ref' IS DISTINCT FROM meton_ledger.legacy_hash(replace(origin::text,'-','')) OR fact->>'used_at' IS NULL OR
                EXISTS(SELECT FROM meton_ledger.legacy_cash_facts WHERE cutoff=p_cutoff AND kind='order' AND proof->>'code_ref'=fact->>'code_ref') OR
                NOT EXISTS(SELECT FROM meton_ledger.legacy_qualification_facts q JOIN meton_ledger.legacy_qualifications o USING(environment,source,eligibility)
                    WHERE (q.environment,q.source,q.eligibility,q.state,o.source_marker)=(p_env,p_source,origin,'received',p_marker)) THEN
                RAISE EXCEPTION 'original grant proof unavailable' USING ERRCODE='23514'; END IF;
            credit_at:=(fact->>'used_at')::timestamptz;
        ELSE
            SELECT proof INTO fact FROM meton_ledger.legacy_cash_facts WHERE cutoff=p_cutoff AND kind='order' AND native_id=v_native_id;
            IF fact IS NULL OR fact->>'state' IS DISTINCT FROM 'COMPLETED' OR fact->>'order_type' IS DISTINCT FROM 'balance' OR
                fact->>'redemption_match' IS DISTINCT FROM 'owned_used' OR fact->>'currency_evidence' IS DISTINCT FROM item->>'denomination' OR
                fact->>'trade_ref' IS NULL OR fact->>'merchant_ref' IS NULL OR fact->>'paid_at' IS NULL OR fact->>'completed_at' IS NULL OR
                (fact->>'credit_amount')::numeric IS DISTINCT FROM qty OR (fact->>'order_pay_amount')::numeric IS DISTINCT FROM face OR (fact->>'bonus')::numeric IS DISTINCT FROM 0::numeric OR
                (fact->>'reported_refund')::numeric IS DISTINCT FROM 0::numeric OR (fact->>'forced_refund')::boolean IS DISTINCT FROM false OR fact->>'refund_requested_at' IS NOT NULL THEN
                RAISE EXCEPTION 'original purchase proof unavailable' USING ERRCODE='23514'; END IF;
            SELECT proof INTO redemption FROM meton_ledger.legacy_cash_facts WHERE cutoff=p_cutoff AND kind='redemption' AND proof->>'code_ref'=fact->>'code_ref';
            IF redemption IS NULL OR redemption->>'state' IS DISTINCT FROM 'used' OR (redemption->>'value')::numeric IS DISTINCT FROM qty THEN
                RAISE EXCEPTION 'original purchase redemption unavailable' USING ERRCODE='23514'; END IF;
            credit_at:=(fact->>'completed_at')::timestamptz;
        END IF;
        INSERT INTO meton_ledger.legacy_source_components VALUES(p_operation,count_lots,item->>'kind',origin,
            CASE WHEN item->>'kind'='grant' THEN 'redemption' ELSE 'order' END,v_native_id,item->>'evidence',item->>'rule',item->>'denomination',face,rate,qty,left_qty,credit_at);
        total:=total+left_qty;
    END LOOP;
    IF total+p_unknown::numeric<>greatest((header->>'balance')::numeric,0) THEN RAISE EXCEPTION 'original balance not accounted for' USING ERRCODE='23514'; END IF;
    RETURN p_operation;
END $$;
CREATE FUNCTION meton_ledger.find_legacy_source_review(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid,p_operation uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('operation',r.operation,'cutoff',r.cutoff,'previous',r.previous,'revision',r.revision,
        'unit',r.unit,'evidence',r.evidence_ref,'known_amount',r.known_amount::text,'unknown_amount',r.unknown_amount::text,
        'original_debt',r.original_debt::text,'original_precharge',r.original_precharge::text,'recorded_at',r.recorded_at,
        'state',CASE WHEN h->>'activity_state'<>'activity_evidence_frozen' OR h->>'cash_state'<>'cash_evidence_frozen' THEN 'evidence_unavailable'
            WHEN r.unknown_amount>0 OR r.original_debt>0 OR r.original_precharge<>0 THEN 'classification_incomplete' ELSE 'classified_needs_activation' END,
        'components',(SELECT coalesce(jsonb_agg(jsonb_build_object('ordinal',c.ordinal,'kind',c.kind,'origin',c.origin,'native_kind',c.native_kind,
            'native_id',c.native_id,'rule',c.rule_version,'denomination',c.denomination,'face',c.face_value::text,'rate',c.conversion_rate::text,
            'original',c.original_amount::text,'remaining',c.remaining::text,'credited_at',c.credited_at,'evidence',c.evidence_ref) ORDER BY c.ordinal),'[]'::jsonb)
            FROM meton_ledger.legacy_source_components c WHERE c.review=r.operation),
        'qualification_facts',r.request->'claims','cash_handoff',h->'cash_handoff','activity_counts',h->'activity_counts')
    FROM meton_ledger.legacy_source_reviews r CROSS JOIN LATERAL
        meton_ledger.find_legacy_activity(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff) h
    WHERE r.cutoff=p_cutoff AND r.operation=p_operation AND h IS NOT NULL
$$;
REVOKE ALL ON FUNCTION meton_ledger.record_legacy_source_review(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.find_legacy_source_review(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid) FROM PUBLIC;
