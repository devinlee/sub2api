-- 每个恢复代次需要重新取得 Identity 原注册事实。已有现金可以先保存，缺少本代事实时等待职能独立的消费者补齐。
ALTER TABLE meton_ledger.cash_account_facts ADD COLUMN projection_epoch bigint CHECK(projection_epoch>0),
    ADD COLUMN projection_sequence bigint CHECK(projection_sequence>0), ADD COLUMN preparing_closure uuid;
ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel','lifecycle'));

CREATE FUNCTION meton_ledger.observe_cash_lifecycle(original jsonb,registration uuid,fact jsonb,deadline timestamptz)
RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE target_epoch bigint:=(original->>'epoch')::bigint; marker uuid:=(original->>'source_marker')::uuid; result text;
    previous meton_ledger.cash_account_facts%ROWTYPE; sequence_id bigint:=(fact->>'sequence')::bigint;
    recovery bigint:=(fact->>'recoveryVersion')::bigint; preparation uuid:=(fact->>'preparingClosure')::uuid;
BEGIN
    IF jsonb_typeof(fact) IS DISTINCT FROM 'object' OR NOT fact ?& ARRAY['lifecycle','securityVersion','recoveryVersion','lastStopVersion','sequence']
        OR (fact-ARRAY['lifecycle','securityVersion','recoveryVersion','lastStopVersion','sequence','preparingClosure'])<>'{}'::jsonb
        OR sequence_id IS NULL OR sequence_id<1 OR deadline IS NULL OR deadline<=clock_timestamp() OR deadline>clock_timestamp()+interval '30 seconds'
        OR preparation IS NOT NULL AND (preparation='00000000-0000-0000-0000-000000000000' OR fact->>'lifecycle'<>'active')
        OR fact->>'lifecycle' NOT IN ('active','closing','security_recovery','closed') OR
        (fact->>'lifecycle' IN ('closing','closed') AND (fact->>'lastStopVersion')::bigint IS DISTINCT FROM (fact->>'securityVersion')::bigint) THEN
        RAISE EXCEPTION 'invalid cash account snapshot' USING ERRCODE='22023'; END IF;
    PERFORM meton_ledger.require_cash_writer(original->>'environment',original->>'source',target_epoch);
    PERFORM FROM public.meton_managed_creations m WHERE (m.environment,m.source,m.epoch,m.meton_user,m.account,m.operation,m.dispatch,m.remote_user,m.source_marker)=
        (original->>'environment',original->>'source',target_epoch,(original->>'user')::uuid,(original->>'account')::uuid,(original->>'creation')::uuid,
         (original->>'dispatch')::uuid,(original->>'remote_user')::bigint,marker);
    IF NOT FOUND THEN RAISE EXCEPTION 'original cash account mismatch' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock(meton_ledger.cash_account_lock(marker));
    SELECT * INTO previous FROM meton_ledger.cash_account_facts f WHERE f.source_marker=marker FOR UPDATE;
    IF FOUND THEN
        IF previous.registration<>registration THEN RAISE EXCEPTION 'original registration mismatch' USING ERRCODE='42501'; END IF;
        IF previous.projection_epoch>target_epoch OR previous.recovery_version>recovery OR
           (previous.projection_epoch=target_epoch AND previous.recovery_version=recovery AND previous.projection_sequence>sequence_id) THEN RETURN 'superseded'; END IF;
        IF (previous.projection_epoch,previous.recovery_version,previous.projection_sequence)=(target_epoch,recovery,sequence_id) THEN
            IF (previous.lifecycle,previous.security_version,previous.last_stop_version,previous.preparing_closure) IS DISTINCT FROM
                (fact->>'lifecycle',(fact->>'securityVersion')::bigint,(fact->>'lastStopVersion')::bigint,preparation) THEN
                RAISE EXCEPTION 'same cash account observation has different contents' USING ERRCODE='23505'; END IF;
            RETURN 'observed';
        END IF;
    END IF;
    result:=meton_ledger.record_cash_account_fact(original->>'environment',original->>'source',target_epoch,original,registration,
        (fact->>'securityVersion')::bigint,(fact->>'recoveryVersion')::bigint,(fact->>'lastStopVersion')::bigint,fact->>'lifecycle',deadline);
    IF result='observed' THEN
        UPDATE meton_ledger.cash_account_facts SET projection_epoch=target_epoch,projection_sequence=sequence_id,preparing_closure=preparation
            WHERE source_marker=marker;
    END IF;
    RETURN result;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.observe_cash_lifecycle(jsonb,uuid,jsonb,timestamptz) FROM PUBLIC;

DO $account$
DECLARE http_def text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    scope_def text:=pg_get_functiondef('meton_ledger.check_checkout_scope(jsonb,jsonb,jsonb,timestamptz)'::regprocedure);
    fulfil_def text:=pg_get_functiondef('meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)'::regprocedure);
    actions constant text:='''issue'',''redeem'',''status'',''quote'',''confirm'',''order'',''present'',''cancel''';
    next_case constant text:='WHEN ''cancel'' THEN'; scope_at constant text:='IF meton_ledger.cash_account_restricted(m.source_marker)';
    credit_at constant text:='SELECT * INTO a FROM meton_ledger.cash_order_awards';
BEGIN
    IF cardinality(string_to_array(http_def,actions))<>2 OR cardinality(string_to_array(http_def,next_case))<>2
        OR cardinality(string_to_array(scope_def,scope_at))<>2 OR cardinality(string_to_array(fulfil_def,credit_at))<>2 THEN
        RAISE EXCEPTION 'original cash scope changed'; END IF;
    http_def:=replace(http_def,actions,actions||',''lifecycle''');
    EXECUTE replace(http_def,next_case,$fact$
        WHEN 'lifecycle' THEN
            IF q-ARRAY['version','origin','intent','accountFact','validUntil']<>'{}'::jsonb THEN
                RAISE EXCEPTION 'unexpected account fact input' USING ERRCODE='42501'; END IF;
            result:=meton_ledger.observe_cash_lifecycle(orig,sid,q->'accountFact',deadline);
        $fact$||next_case);
    EXECUTE replace(scope_def,scope_at,$gate$
        IF NOT EXISTS(SELECT FROM meton_ledger.cash_account_facts f WHERE f.source_marker=m.source_marker AND f.lifecycle='active' AND f.preparing_closure IS NULL
            AND (f.projection_epoch,f.security_version,f.recovery_version)=(m.epoch,(p_desktop->>'security_version')::bigint,
                (p_desktop->>'recovery_version')::bigint)) THEN
            RAISE EXCEPTION 'original cash account proof required' USING ERRCODE='42501'; END IF;
        $gate$||scope_at);
    EXECUTE replace(fulfil_def,credit_at,$gate$
        IF NOT EXISTS(SELECT FROM meton_ledger.cash_account_facts f WHERE f.source_marker=marker AND f.projection_epoch=generation AND f.preparing_closure IS NULL) THEN
            RETURN jsonb_build_object('state','account_pending','payment',payment,'version',d.version); END IF;
        $gate$||credit_at);
END $account$;
CREATE FUNCTION meton_ledger.http_checkout_lifecycle(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.apply_checkout_http('lifecycle',$1,$2,$3,$4,$5,$6)
$$;
REVOKE ALL ON FUNCTION meton_ledger.http_checkout_lifecycle(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC;
