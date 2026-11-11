-- 订单上的停止事实独立于收银台窗口和现金事实。每笔原单只能有一个关闭流程和一个可能外发的关单票据。
CREATE TABLE meton_ledger.cash_order_stops(
    native_order bigint PRIMARY KEY, intent_id uuid NOT NULL UNIQUE, source_marker uuid NOT NULL,
    reason text NOT NULL CHECK(reason IN ('member_cancel','expired','account_restricted')),
    phase text NOT NULL CHECK(phase IN ('awaiting_query','possibly_sent','unknown','closed_local','closed_channel','paid_review','review')),
    version bigint NOT NULL CHECK(version>=2), requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    close_dispatch uuid UNIQUE, sent_at timestamptz, lease uuid, lease_generation bigint,
    next_probe timestamptz NOT NULL DEFAULT clock_timestamp(), last_evidence bytea CHECK(octet_length(last_evidence)=32),
    FOREIGN KEY(native_order,intent_id,source_marker) REFERENCES meton_ledger.cash_orders(native_order,intent_id,source_marker),
    CHECK((close_dispatch IS NULL)=(sent_at IS NULL)), CHECK((lease IS NULL)=(lease_generation IS NULL))
);
CREATE INDEX cash_stop_due ON meton_ledger.cash_order_stops(next_probe,native_order) WHERE phase IN ('awaiting_query','possibly_sent','unknown');

-- 这里只接收原账号的权威生命周期快照，不保存登录资料，也不按会话退出事件推断账号关闭。
CREATE TABLE meton_ledger.cash_account_facts(
    source_marker uuid PRIMARY KEY REFERENCES public.meton_managed_creations(source_marker),
    registration uuid NOT NULL, user_id uuid NOT NULL, account_id uuid NOT NULL, creation uuid NOT NULL,
    security_version bigint NOT NULL CHECK(security_version>0), recovery_version bigint NOT NULL CHECK(recovery_version>0),
    last_stop_version bigint NOT NULL CHECK(last_stop_version BETWEEN 0 AND security_version),
    lifecycle text NOT NULL CHECK(lifecycle IN ('active','security_recovery','closing','closed','disabled')),
    observed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE FUNCTION meton_ledger.cash_account_lock(marker uuid) RETURNS bigint LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT hashtextextended('cash-account:'||marker::text,0) $$;

CREATE FUNCTION meton_ledger.cash_account_restricted(marker uuid) RETURNS boolean LANGUAGE sql STABLE
SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT EXISTS(SELECT FROM public.meton_managed_creations m JOIN public.users u ON u.id=m.remote_user
        WHERE m.source_marker=marker AND u.status='active' AND u.role='user' AND u.deleted_at IS NULL)
        OR EXISTS(SELECT FROM meton_ledger.cash_account_facts a WHERE a.source_marker=marker AND a.lifecycle IN ('closing','closed','disabled'))
        OR EXISTS(SELECT FROM meton_ledger.gift_terminations t WHERE t.source_marker=marker)
$$;

CREATE TABLE meton_ledger.cash_stop_generations(
    source_marker uuid PRIMARY KEY REFERENCES public.meton_managed_creations(source_marker),
    generation bigint NOT NULL CHECK(generation>0)
);
ALTER TABLE meton_ledger.checkout_handoffs ADD COLUMN stop_generation bigint NOT NULL DEFAULT 0 CHECK(stop_generation>=0);
ALTER TABLE meton_ledger.cash_orders ADD COLUMN stop_generation bigint NOT NULL DEFAULT 0 CHECK(stop_generation>=0);
CREATE FUNCTION meton_ledger.cash_generation(marker uuid) RETURNS bigint LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT coalesce((SELECT generation FROM meton_ledger.cash_stop_generations WHERE source_marker=marker),0)
$$;
CREATE FUNCTION meton_ledger.advance_cash_generation(marker uuid) RETURNS void LANGUAGE sql SET search_path=pg_catalog,pg_temp AS $$
    INSERT INTO meton_ledger.cash_stop_generations AS g VALUES(marker,1) ON CONFLICT(source_marker) DO UPDATE SET generation=g.generation+1
$$;
CREATE FUNCTION meton_ledger.capture_cash_generation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF meton_ledger.cash_account_restricted(NEW.source_marker) THEN RAISE EXCEPTION 'cash admission restricted' USING ERRCODE='42501'; END IF;
    NEW.stop_generation:=meton_ledger.cash_generation(NEW.source_marker);
    IF TG_TABLE_NAME='cash_orders' AND NOT EXISTS(SELECT FROM meton_ledger.checkout_handoffs h WHERE
        (h.intent_id,h.source_marker,h.stop_generation)=(NEW.intent_id,NEW.source_marker,NEW.stop_generation)) THEN
        RAISE EXCEPTION 'obsolete cashier admission' USING ERRCODE='42501'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER capture_cash_generation BEFORE INSERT ON meton_ledger.checkout_handoffs FOR EACH ROW EXECUTE FUNCTION meton_ledger.capture_cash_generation();
CREATE TRIGGER capture_cash_generation BEFORE INSERT ON meton_ledger.cash_orders FOR EACH ROW EXECUTE FUNCTION meton_ledger.capture_cash_generation();
ALTER TABLE meton_ledger.checkout_handoffs ENABLE ALWAYS TRIGGER capture_cash_generation;
ALTER TABLE meton_ledger.cash_orders ENABLE ALWAYS TRIGGER capture_cash_generation;
-- 原生账号短暂禁用也留断点。即使后来重新开放，新订单用新代次，旧订单不能借恢复重新获得履约资格。
CREATE FUNCTION meton_ledger.close_native_cash_generation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid;
BEGIN
    SELECT source_marker INTO marker FROM public.meton_managed_creations WHERE remote_user=NEW.id;
    IF FOUND THEN PERFORM meton_ledger.advance_cash_generation(marker); END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER close_native_cash_generation AFTER UPDATE OF status,role,deleted_at ON public.users FOR EACH ROW
    WHEN (OLD.role='user' AND OLD.status='active' AND OLD.deleted_at IS NULL AND
        (NEW.role<>'user' OR NEW.status<>'active' OR NEW.deleted_at IS NOT NULL))
    EXECUTE FUNCTION meton_ledger.close_native_cash_generation();
ALTER TABLE public.users ENABLE ALWAYS TRIGGER close_native_cash_generation;
CREATE FUNCTION meton_ledger.order_account_restricted(o meton_ledger.cash_orders) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.cash_account_restricted(o.source_marker) OR o.stop_generation<>meton_ledger.cash_generation(o.source_marker)
$$;

CREATE FUNCTION meton_ledger.record_cash_account_fact(deployment text,source_name text,generation bigint,
    original jsonb,registration uuid,security_version bigint,recovery_version bigint,last_stop_version bigint,lifecycle text,until_at timestamptz)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations%ROWTYPE; earlier meton_ledger.cash_account_facts%ROWTYPE;
BEGIN
    PERFORM meton_ledger.require_cash_writer(deployment,source_name,generation);
    IF num_nulls(original,registration,security_version,recovery_version,last_stop_version,lifecycle,until_at)>0 OR registration='00000000-0000-0000-0000-000000000000'
        OR security_version<1 OR recovery_version<1 OR lifecycle NOT IN ('active','security_recovery','closing','closed','disabled')
        OR last_stop_version NOT BETWEEN 0 AND security_version OR (lifecycle IN ('closing','closed','disabled') AND last_stop_version=0)
        OR until_at<=clock_timestamp() OR until_at>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'invalid original account fact' USING ERRCODE='22023'; END IF;
    SELECT * INTO STRICT m FROM public.meton_managed_creations WHERE (environment,source,epoch,meton_user,account,operation,dispatch,remote_user,source_marker)=
        (deployment,source_name,generation,(original->>'user')::uuid,(original->>'account')::uuid,(original->>'creation')::uuid,
         (original->>'dispatch')::uuid,(original->>'remote_user')::bigint,(original->>'source_marker')::uuid);
    PERFORM pg_advisory_xact_lock(meton_ledger.cash_account_lock(m.source_marker));
    SELECT * INTO earlier FROM meton_ledger.cash_account_facts f WHERE f.source_marker=m.source_marker FOR UPDATE;
    IF FOUND THEN
        IF (earlier.registration,earlier.user_id,earlier.account_id,earlier.creation) IS DISTINCT FROM
            (registration,m.meton_user,m.account,m.operation) THEN RAISE EXCEPTION 'original registration differs' USING ERRCODE='42501'; END IF;
        IF recovery_version<earlier.recovery_version OR security_version<earlier.security_version OR last_stop_version<earlier.last_stop_version
            OR earlier.lifecycle='closed' AND lifecycle<>'closed' THEN RETURN 'superseded'; END IF;
        IF (earlier.recovery_version,earlier.security_version,earlier.last_stop_version,earlier.lifecycle)=(recovery_version,security_version,last_stop_version,lifecycle) THEN RETURN 'observed'; END IF;
        -- Identity 在接受注销时推进安全代次。相同代次的撤回可以经恢复返回 active，迟到的 closing 不得倒退。
        IF (recovery_version,security_version,last_stop_version)=(earlier.recovery_version,earlier.security_version,earlier.last_stop_version)
            AND earlier.lifecycle<>lifecycle AND NOT ((earlier.lifecycle='security_recovery' AND lifecycle='active') OR
                    (earlier.lifecycle='closing' AND lifecycle IN ('security_recovery','active','closed'))) THEN RETURN 'superseded'; END IF;
    END IF;
    IF until_at<=clock_timestamp() THEN RAISE EXCEPTION 'original account proof expired' USING ERRCODE='55000'; END IF;
    IF last_stop_version>coalesce(earlier.last_stop_version,0) THEN PERFORM meton_ledger.advance_cash_generation(m.source_marker); END IF;
    INSERT INTO meton_ledger.cash_account_facts VALUES(m.source_marker,registration,m.meton_user,m.account,m.operation,security_version,
        recovery_version,last_stop_version,lifecycle,clock_timestamp()) ON CONFLICT(source_marker) DO UPDATE SET security_version=excluded.security_version,
        recovery_version=excluded.recovery_version,last_stop_version=excluded.last_stop_version,lifecycle=excluded.lifecycle,observed_at=excluded.observed_at;
    RETURN 'observed';
END $$;

CREATE FUNCTION meton_ledger.restrict_unposted_payment(payment uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE p meton_ledger.cash_payments%ROWTYPE; d meton_ledger.cash_payment_dispositions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT p FROM meton_ledger.cash_payments WHERE payment_id=payment;
    SELECT * INTO STRICT d FROM meton_ledger.cash_payment_dispositions WHERE payment_id=payment FOR UPDATE;
    IF d.state='resolved' OR EXISTS(SELECT FROM meton_ledger.cash_parts WHERE payment_id=payment AND basis='purchased_source') THEN RETURN; END IF;
    IF d.state IN ('ready','received') THEN UPDATE meton_ledger.cash_payment_dispositions SET state='restricted',version=version+1 WHERE payment_id=payment; END IF;
    IF p.payer_fen>0 AND NOT EXISTS(SELECT FROM meton_ledger.cash_parts WHERE payment_id=payment) THEN
        INSERT INTO meton_ledger.cash_parts(part_id,payment_id,native_order,source_marker,basis,basis_fen)
            VALUES(gen_random_uuid(),payment,p.native_order,p.source_marker,'unposted_cash',p.payer_fen);
    END IF;
END $$;

CREATE FUNCTION meton_ledger.stop_original_order(marker uuid,original uuid,why text)
RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE o meton_ledger.cash_orders%ROWTYPE; s meton_ledger.cash_order_stops%ROWTYPE;
    a meton_ledger.cash_order_attempts%ROWTYPE; pay uuid; phase text;
BEGIN
    IF why NOT IN ('member_cancel','expired','account_restricted') OR why IS NULL THEN RAISE EXCEPTION 'invalid order stop' USING ERRCODE='22023'; END IF;
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(marker));
    SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE intent_id=original AND source_marker=marker FOR UPDATE;
    SELECT * INTO STRICT a FROM meton_ledger.cash_order_attempts WHERE native_order=o.native_order FOR UPDATE;
    SELECT * INTO s FROM meton_ledger.cash_order_stops WHERE native_order=o.native_order;
    IF FOUND THEN RETURN s.phase; END IF;
    IF why='expired' AND o.expires_at>clock_timestamp() OR why='account_restricted' AND NOT meton_ledger.order_account_restricted(o) THEN
        RAISE EXCEPTION 'stop reason not current' USING ERRCODE='55000'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_payments WHERE native_order=o.native_order) THEN
        IF why<>'account_restricted' OR EXISTS(SELECT FROM meton_ledger.cash_parts WHERE native_order=o.native_order AND basis='purchased_source') THEN RETURN 'paid'; END IF;
        phase:='paid_review';
        FOR pay IN SELECT payment_id FROM meton_ledger.cash_payments WHERE native_order=o.native_order LOOP
            PERFORM meton_ledger.restrict_unposted_payment(pay);
        END LOOP;
    ELSIF a.dispatch_id IS NULL THEN phase:='closed_local';
    ELSE phase:='awaiting_query'; END IF;
    INSERT INTO meton_ledger.cash_order_stops(native_order,intent_id,source_marker,reason,phase,version)
        VALUES(o.native_order,original,marker,why,phase,2);
    RETURN phase;
END $$;

-- 现有报价、确认和支付认领须与停止操作使用同一原单锁，并复验当前账号。窗口退出仍只撤销该会话。
DO $guards$
DECLARE scope_def text:=pg_get_functiondef('meton_ledger.check_checkout_scope(jsonb,jsonb,jsonb,timestamptz)'::regprocedure);
    auth_def text:=pg_get_functiondef('meton_ledger.authorize_checkout_order(jsonb,jsonb,jsonb,uuid,bytea,timestamptz)'::regprocedure);
    dispatch_def text:=pg_get_functiondef('meton_ledger.claim_purchase_dispatch(jsonb,jsonb,jsonb,uuid,bytea,uuid,timestamptz)'::regprocedure);
    observe_def text:=pg_get_functiondef('meton_ledger.observe_cash_payment(text,text,bigint,jsonb,jsonb)'::regprocedure);
    fulfil_def text:=pg_get_functiondef('meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)'::regprocedure);
    scope_at constant text:='FOREACH who IN ARRAY'; auth_at constant text:='AND browser=p_browser AND web_hash='; dispatch_at constant text:='PERFORM 1 FROM meton_ledger.cash_order_attempts';
    observation_at constant text:='SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE intent_id=';
    qualify_at constant text:='IF first_payment AND paid BETWEEN'; fulfil_at constant text:='SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE (intent_id,source_marker)';
    prior_award constant text:='SELECT * INTO a FROM meton_ledger.cash_order_awards';
    after_user constant text:='SELECT * INTO STRICT effect FROM meton_ledger.credit_origin';
BEGIN
    IF cardinality(string_to_array(scope_def,scope_at))<>2 OR cardinality(string_to_array(auth_def,auth_at))<>2 OR cardinality(string_to_array(dispatch_def,dispatch_at))<>2 OR
        cardinality(string_to_array(observe_def,observation_at))<>2 OR cardinality(string_to_array(observe_def,qualify_at))<>2 OR
        cardinality(string_to_array(fulfil_def,fulfil_at))<>2 OR cardinality(string_to_array(fulfil_def,prior_award))<>2 OR
        cardinality(string_to_array(fulfil_def,after_user))<>2 OR cardinality(string_to_array(observe_def,'SELECT * INTO STRICT d FROM meton_ledger.cash_payment_dispositions'))<>2 THEN
        RAISE EXCEPTION 'original cash admission changed'; END IF;
    EXECUTE replace(scope_def,scope_at,$lock$PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(m.source_marker));
        IF meton_ledger.cash_account_restricted(m.source_marker) OR EXISTS(SELECT FROM meton_ledger.cash_account_facts fact
            WHERE fact.source_marker=m.source_marker AND (fact.lifecycle='security_recovery'
            OR fact.security_version>(p_desktop->>'security_version')::bigint
            OR fact.recovery_version>(p_desktop->>'recovery_version')::bigint)) THEN
            RAISE EXCEPTION 'account or checkout credentials restricted' USING ERRCODE='42501'; END IF;
        $lock$||scope_at);
    EXECUTE replace(auth_def,auth_at,'AND stop_generation=meton_ledger.cash_generation(marker) '||auth_at);
    EXECUTE replace(dispatch_def,dispatch_at,$lock$PERFORM FROM meton_ledger.cash_orders WHERE intent_id=i AND source_marker=(o->>'source_marker')::uuid FOR UPDATE;
        IF EXISTS(SELECT FROM meton_ledger.cash_order_stops stop WHERE stop.intent_id=i) THEN RETURN NULL; END IF;
        $lock$||dispatch_at);
    observe_def:=replace(observe_def,observation_at,$lock$PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((origin->>'sourceMarker')::uuid));
        $lock$||observation_at);
    observe_def:=replace(observe_def,qualify_at,$stop$IF first_payment AND NOT meton_ledger.order_account_restricted(o)
        AND NOT EXISTS(SELECT FROM meton_ledger.cash_order_stops WHERE native_order=o.native_order) AND paid BETWEEN$stop$);
    EXECUTE replace(observe_def,'SELECT * INTO STRICT d FROM meton_ledger.cash_payment_dispositions',$late$
        UPDATE meton_ledger.cash_order_stops SET phase='paid_review',version=version+1,lease=NULL,lease_generation=NULL
            WHERE native_order=o.native_order AND phase<>'paid_review';
        $late$||'SELECT * INTO STRICT d FROM meton_ledger.cash_payment_dispositions');
    fulfil_def:=replace(fulfil_def,fulfil_at,$lock$PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(marker));
        $lock$||fulfil_at);
    fulfil_def:=replace(fulfil_def,prior_award,$stop$
        IF meton_ledger.order_account_restricted(o) OR EXISTS(SELECT FROM meton_ledger.cash_order_stops WHERE native_order=o.native_order) THEN
            PERFORM meton_ledger.restrict_unposted_payment(payment);
            RETURN jsonb_build_object('state','restricted','payment',payment,'version',
                (SELECT version FROM meton_ledger.cash_payment_dispositions WHERE payment_id=payment));
        END IF;
        $stop$||prior_award);
    EXECUTE replace(fulfil_def,after_user,$check$IF meton_ledger.order_account_restricted(o) THEN
        PERFORM meton_ledger.restrict_unposted_payment(payment);
        RETURN jsonb_build_object('state','restricted','payment',payment);
    END IF;
    $check$||after_user);
END $guards$;
REVOKE ALL ON meton_ledger.cash_order_stops,meton_ledger.cash_account_facts,meton_ledger.cash_stop_generations FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.cash_account_lock(uuid),meton_ledger.cash_account_restricted(uuid),
    meton_ledger.record_cash_account_fact(text,text,bigint,jsonb,uuid,bigint,bigint,bigint,text,timestamptz),
    meton_ledger.capture_cash_generation(),meton_ledger.close_native_cash_generation(),meton_ledger.cash_generation(uuid),
    meton_ledger.advance_cash_generation(uuid),meton_ledger.order_account_restricted(meton_ledger.cash_orders),
    meton_ledger.stop_original_order(uuid,uuid,text),meton_ledger.restrict_unposted_payment(uuid) FROM PUBLIC;

-- 取消只能由原收银台明确提出。关闭窗口没有这项命令；同一原意图重试只能看到原停止事实。
CREATE FUNCTION meton_ledger.cancel_original_checkout(orig jsonb,desk jsonb,browser jsonb,original uuid,web bytea,
    expected_version bigint,until_at timestamptz) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE o meton_ledger.cash_orders%ROWTYPE; s meton_ledger.cash_order_stops%ROWTYPE;
BEGIN
    PERFORM meton_ledger.authorize_checkout_order(orig,desk,browser,original,web,until_at);
    SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE intent_id=original AND source_marker=(orig->>'source_marker')::uuid FOR UPDATE;
    SELECT * INTO s FROM meton_ledger.cash_order_stops WHERE native_order=o.native_order;
    IF expected_version IS NULL OR expected_version<1 OR expected_version>coalesce(s.version,1) THEN
        RAISE EXCEPTION 'original order version differs' USING ERRCODE='23505'; END IF;
    IF until_at<=clock_timestamp() THEN RAISE EXCEPTION 'cancel proof expired' USING ERRCODE='55000'; END IF;
    IF s.native_order IS NOT NULL THEN RETURN s.phase; END IF;
    RETURN meton_ledger.stop_original_order(o.source_marker,original,'member_cancel');
END $$;
REVOKE ALL ON FUNCTION meton_ledger.cancel_original_checkout(jsonb,jsonb,jsonb,uuid,bytea,bigint,timestamptz) FROM PUBLIC;

DO $lookup$
DECLARE original text:=pg_get_functiondef('meton_ledger.read_original_purchase(jsonb,uuid,timestamptz)'::regprocedure);
    cash_att constant text:='''paymentConfirmed'',EXISTS(';
    active_query text:=pg_get_functiondef('meton_ledger.claim_original_cash_query(jsonb,integer)'::regprocedure);
    due_att constant text:='AND a.dispatch_id IS NOT NULL';
BEGIN
    IF cardinality(string_to_array(original,cash_att))<>2 OR cardinality(string_to_array(active_query,due_att))<>2 THEN
        RAISE EXCEPTION 'purchase query signature changed'; END IF;
    EXECUTE replace(original,cash_att,$control$'closeState',CASE WHEN c.native_order IS NULL THEN 'open'
            ELSE coalesce((SELECT s.phase FROM meton_ledger.cash_order_stops s WHERE s.native_order=c.native_order),
                CASE WHEN EXISTS(SELECT FROM meton_ledger.cash_payments p WHERE p.native_order=c.native_order) THEN 'open'
                     WHEN meton_ledger.order_account_restricted(c) OR c.expires_at<=clock_timestamp() THEN 'stop_due' ELSE 'open' END) END,
        'closeVersion',coalesce((SELECT s.version FROM meton_ledger.cash_order_stops s WHERE s.native_order=c.native_order),1),
        $control$||cash_att);
    EXECUTE replace(active_query,due_att,$only$AND NOT EXISTS(SELECT FROM meton_ledger.cash_order_stops s WHERE s.native_order=c.native_order)
        $only$||due_att);
END $lookup$;

ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel'));
DO $cashier$
DECLARE src text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    allowed constant text:='''issue'',''redeem'',''status'',''quote'',''confirm'',''order'',''present''';
    order_branch constant text:='WHEN ''order'' THEN';
    show_code constant text:='AND q->>''wantCode''=''true''';
BEGIN
    IF cardinality(string_to_array(src,allowed))<>2 OR cardinality(string_to_array(src,order_branch))<>2 OR
        cardinality(string_to_array(src,show_code))<>2 THEN RAISE EXCEPTION 'original checkout HTTP changed'; END IF;
    src:=replace(src,allowed,allowed||',''cancel''');
    src:=replace(src,order_branch,$cancel$
        WHEN 'cancel' THEN
            result:=meton_ledger.cancel_original_checkout(orig,desk,web_subject,sid,decode(q->>'webProof','base64'),
                (q->>'closeVersion')::bigint,deadline);
        $cancel$||order_branch);
    EXECUTE replace(src,show_code,show_code||' AND result::jsonb->>''closeState''=''open''');
END $cashier$;
CREATE FUNCTION meton_ledger.http_checkout_cancel(text,text,bigint,timestamptz,bigint,text)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.apply_checkout_http('cancel',$1,$2,$3,$4,$5,$6)
$$;
REVOKE ALL ON FUNCTION meton_ledger.http_checkout_cancel(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC;

-- 停止事实发现与渠道网络操作分别提交。过了配置核对窗口仍未确定的原单转核对，不能据此写成已关。
CREATE FUNCTION meton_ledger.claim_order_stop(route jsonb,window_seconds integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE o meton_ledger.cash_orders%ROWTYPE; s meton_ledger.cash_order_stops%ROWTYPE; candidate record; token uuid;
BEGIN
    PERFORM meton_ledger.require_cash_writer(route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    IF window_seconds IS NULL OR window_seconds NOT BETWEEN 60 AND 2678400 OR meton_ledger.notification_system_id() IS DISTINCT FROM route->>'sourceSystem' THEN
        RAISE EXCEPTION 'stop worker scope unavailable' USING ERRCODE='42501'; END IF;
    SELECT c.source_marker,c.intent_id,CASE WHEN meton_ledger.order_account_restricted(c) THEN 'account_restricted' ELSE 'expired' END AS why INTO candidate
        FROM meton_ledger.cash_orders c JOIN public.meton_managed_creations m USING(source_marker)
        WHERE (c.channel,c.cash_environment,c.merchant_id,c.app_id,m.environment,m.source,m.epoch)=
            (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',route->>'deployment',route->>'source',(route->>'epoch')::bigint)
          AND NOT EXISTS(SELECT FROM meton_ledger.cash_order_stops already WHERE already.native_order=c.native_order)
          AND (c.expires_at<=clock_timestamp() OR meton_ledger.order_account_restricted(c))
          AND NOT EXISTS(SELECT FROM meton_ledger.cash_parts part WHERE part.native_order=c.native_order AND part.basis='purchased_source')
          AND (meton_ledger.order_account_restricted(c) OR NOT EXISTS(SELECT FROM meton_ledger.cash_payments p WHERE p.native_order=c.native_order))
        ORDER BY c.expires_at,c.native_order LIMIT 1;
    IF FOUND THEN PERFORM meton_ledger.stop_original_order(candidate.source_marker,candidate.intent_id,candidate.why); END IF;
    SELECT st.* INTO s FROM meton_ledger.cash_order_stops st JOIN meton_ledger.cash_orders c USING(native_order,intent_id,source_marker)
        JOIN public.meton_managed_creations m USING(source_marker)
        WHERE (c.channel,c.cash_environment,c.merchant_id,c.app_id,m.environment,m.source,m.epoch)=
            (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',route->>'deployment',route->>'source',(route->>'epoch')::bigint)
        AND st.phase IN ('awaiting_query','possibly_sent','unknown') AND st.next_probe<=clock_timestamp()
        ORDER BY st.next_probe,st.native_order LIMIT 1 FOR UPDATE OF st SKIP LOCKED;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF s.requested_at+make_interval(secs=>window_seconds)<=clock_timestamp() THEN
        UPDATE meton_ledger.cash_order_stops SET phase='review',version=version+1,lease=NULL,lease_generation=NULL WHERE native_order=s.native_order;
        RETURN NULL; END IF;
    token:=gen_random_uuid();
    UPDATE meton_ledger.cash_order_stops SET lease=token,lease_generation=(route->>'epoch')::bigint,next_probe=clock_timestamp()+interval '30 seconds'
        WHERE native_order=s.native_order;
    SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE native_order=s.native_order;
    RETURN jsonb_build_object('intent',o.intent_id,'marker',o.source_marker,'token',token,'order',o.out_trade_no,'priceFen',o.price_fen,
        'paramsHash',o.params_hash,'version',s.version,'dispatch',s.close_dispatch);
END $$;

-- 一次已签名的原单查明未付才能发放关单票据。该票据从不续发，失联的执行者只能按原单查询。
CREATE FUNCTION meton_ledger.advance_order_stop(route jsonb,original uuid,marker uuid,token uuid,expected bigint,
    outcome text,dispatch uuid,evidence bytea)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s meton_ledger.cash_order_stops%ROWTYPE; o meton_ledger.cash_orders%ROWTYPE; next_phase text;
BEGIN
    PERFORM meton_ledger.require_cash_writer(route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    IF meton_ledger.notification_system_id() IS DISTINCT FROM route->>'sourceSystem' OR outcome IS NULL OR outcome NOT IN
        ('unpaid','paying','paid','channel_closed','query_unknown','close_accepted','close_unknown') THEN
        RAISE EXCEPTION 'invalid close observation' USING ERRCODE='22023'; END IF;
    IF outcome NOT IN ('query_unknown','close_unknown') AND (evidence IS NULL OR octet_length(evidence)<>32) THEN
        RAISE EXCEPTION 'verified original close evidence required' USING ERRCODE='22023'; END IF;
    SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE (intent_id,source_marker,channel,cash_environment,merchant_id,app_id)=
        (original,marker,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') FOR UPDATE;
    SELECT * INTO STRICT s FROM meton_ledger.cash_order_stops WHERE native_order=o.native_order FOR UPDATE;
    IF (s.lease,s.lease_generation,s.version) IS DISTINCT FROM (token,(route->>'epoch')::bigint,expected)
        OR token IS NULL OR s.next_probe<=clock_timestamp() OR s.phase NOT IN ('awaiting_query','possibly_sent','unknown') THEN
        RETURN jsonb_build_object('state','superseded','version',s.version); END IF;
    IF outcome IN ('close_accepted','close_unknown') AND (dispatch IS NULL OR dispatch IS DISTINCT FROM s.close_dispatch) THEN
        RAISE EXCEPTION 'wrong original close dispatch' USING ERRCODE='42501'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_payments WHERE native_order=o.native_order) OR outcome='paid' THEN next_phase:='paid_review';
    ELSIF outcome IN ('channel_closed','close_accepted') THEN next_phase:='closed_channel';
    ELSIF outcome='unpaid' AND s.close_dispatch IS NULL THEN
        UPDATE meton_ledger.cash_order_stops SET phase='possibly_sent',version=version+1,close_dispatch=gen_random_uuid(),sent_at=clock_timestamp(),
            last_evidence=evidence WHERE native_order=o.native_order RETURNING * INTO s;
        RETURN jsonb_build_object('state','send','version',s.version,'dispatch',s.close_dispatch);
    ELSIF s.close_dispatch IS NOT NULL THEN next_phase:='unknown';
    ELSE next_phase:='awaiting_query'; END IF;
    UPDATE meton_ledger.cash_order_stops SET phase=next_phase,version=version+1,lease=NULL,lease_generation=NULL,
        next_probe=clock_timestamp()+interval '30 seconds',last_evidence=coalesce(evidence,last_evidence) WHERE native_order=o.native_order RETURNING * INTO s;
    RETURN jsonb_build_object('state',s.phase,'version',s.version);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.claim_order_stop(jsonb,integer),
    meton_ledger.advance_order_stop(jsonb,uuid,uuid,uuid,bigint,text,uuid,bytea) FROM PUBLIC;
