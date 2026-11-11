-- 意图是重试入口；报价是本次确认的不可变参数；退款仍只有原订单的现金子记录。
ALTER TABLE meton_ledger.cash_refund_quotes ADD UNIQUE(quote_id,source_marker);
ALTER TABLE meton_ledger.cash_refunds ADD UNIQUE(intent_id,refund_id);
CREATE TABLE meton_ledger.cash_refund_decisions(
    intent_id uuid PRIMARY KEY, source_marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker),
    quote_id uuid NOT NULL, basis_version text NOT NULL CHECK(basis_version ~ '^[0-9a-f]{64}$'),
    confirmed_fen bigint NOT NULL CHECK(confirmed_fen>0), state text NOT NULL CHECK(state IN
        ('accepted','expired','stale_quote','quote_used','refund_pending','recovery_review','review','insufficient','below_minimum')),
    refund_id uuid UNIQUE, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY(quote_id,source_marker) REFERENCES meton_ledger.cash_refund_quotes(quote_id,source_marker),
    FOREIGN KEY(intent_id,refund_id) REFERENCES meton_ledger.cash_refunds(intent_id,refund_id),
    CHECK((state='accepted')=(refund_id IS NOT NULL))
);
CREATE UNIQUE INDEX cash_quote_accepted_once ON meton_ledger.cash_refund_decisions(quote_id) WHERE refund_id IS NOT NULL;
CREATE TRIGGER immutable_refund_decision BEFORE UPDATE OR DELETE ON meton_ledger.cash_refund_decisions
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_refund_decisions ENABLE ALWAYS TRIGGER immutable_refund_decision;
REVOKE ALL ON meton_ledger.cash_refund_decisions FROM PUBLIC;

-- 复用 S2 已冻结的真实差额。旧报价在升级或余额再次变化后都须重新核对。
DO $terms$
DECLARE def text:=pg_get_functiondef('meton_ledger.original_refund_snapshot(jsonb,bigint,uuid,uuid,text)'::regprocedure);
    gate constant text:='IF EXISTS(SELECT FROM meton_ledger.cash_refunds WHERE native_order=order_id AND phase NOT IN';
    snapshot_at constant text:='''originalUnits'',original_units::text,''availableUnits''';
BEGIN
    IF cardinality(string_to_array(def,gate))<>2 OR cardinality(string_to_array(def,snapshot_at))<>2 THEN RAISE EXCEPTION 'refund snapshot changed'; END IF;
    def:=replace(def,gate,'IF meton_ledger.has_text_shortfall(marker) THEN RETURN jsonb_build_object(''state'',''review''); END IF; '||gate);
    EXECUTE replace(def,snapshot_at,$pricing$'rounding','cny-cumulative-half-up-v1','ruleVersion',coalesce(lot.rule_version,historic_source->>'ruleVersion'),
        'originalUnits',original_units::text,'availableUnits'$pricing$);
END $terms$;

CREATE FUNCTION meton_ledger.require_refund_actor(owner jsonb,actor jsonb,until_at timestamptz) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.require_refund_owner(owner);
    IF pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_ledger','CREATE')
        OR EXISTS(SELECT FROM pg_roles r WHERE (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR
            r.rolname IN ('pg_write_all_data','pg_execute_server_program','pg_read_server_files','pg_write_server_files'))
            AND pg_has_role(session_user,r.oid,'MEMBER'))
        OR EXISTS(SELECT FROM pg_class t WHERE t.relkind IN ('r','p') AND (t.relnamespace='meton_ledger'::regnamespace OR t.oid IN
            ('public.users'::regclass,'public.payment_orders'::regclass,'public.meton_managed_fence'::regclass,'public.meton_managed_creations'::regclass,
             'public.meton_managed_session_closures'::regclass))
            AND (has_any_column_privilege(session_user,t.oid,'INSERT,UPDATE') OR has_table_privilege(session_user,t.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted refund authority required' USING ERRCODE='42501'; END IF;
    IF until_at IS NULL OR until_at<=clock_timestamp() OR until_at>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'refund session check expired' USING ERRCODE='55000'; END IF;
    -- 本机和来源都按本次真实会话的身份工作。这里复验代次及账号状态，不以来源映射代替 Identity 的会话撤销裁决。
    IF ((actor->>'user')::uuid=(owner->>'user')::uuid AND (actor->>'session')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid AND
        (actor->>'family')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid) IS NOT TRUE OR EXISTS(
        SELECT FROM public.meton_managed_session_closures WHERE source_marker=(owner->>'source_marker')::uuid AND session_id=(actor->>'session')::uuid) OR NOT EXISTS(
        SELECT FROM meton_ledger.cash_account_facts f JOIN public.users u ON u.id=(owner->>'remote_user')::bigint
        WHERE (f.source_marker,f.user_id,f.account_id,f.creation,f.projection_epoch,f.security_version,f.recovery_version)=
            ((owner->>'source_marker')::uuid,(actor->>'user')::uuid,(owner->>'account')::uuid,(owner->>'creation')::uuid,(owner->>'epoch')::bigint,
             (actor->>'security_version')::bigint,(actor->>'recovery_version')::bigint)
          AND f.lifecycle='active' AND f.preparing_closure IS NULL AND u.role='user' AND u.status='active' AND u.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'refund account session unavailable' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION meton_ledger.original_refund_id(marker uuid,intent uuid) RETURNS uuid
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp AS $$
    WITH key AS (SELECT substring(sha256(convert_to('meton.cash.refund.v1','UTF8')||uuid_send(marker)||uuid_send(intent)) FROM 1 FOR 16) AS raw)
    SELECT encode(set_byte(set_byte(raw,6,(get_byte(raw,6)&15)|128),8,(get_byte(raw,8)&63)|128),'hex')::uuid FROM key
$$;

CREATE FUNCTION meton_ledger.read_original_refund_decision(owner jsonb,actor jsonb,intent uuid,until_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb;
BEGIN
    PERFORM meton_ledger.require_refund_actor(owner,actor,until_at);
    SELECT jsonb_build_object('state',d.state,'intent',d.intent_id,'quote',d.quote_id,'basisVersion',d.basis_version,'fen',d.confirmed_fen,
        'order',(q.request->>'order')::bigint,'basis',q.request->>'basis','units',q.request->>'units','refund',r.refund_id,
        'refundOrder',r.out_refund_no,'phase',r.phase,'version',r.disposition_version)
        INTO result FROM meton_ledger.cash_refund_decisions d JOIN meton_ledger.cash_refund_quotes q ON q.quote_id=d.quote_id
        LEFT JOIN meton_ledger.cash_refunds r ON (r.refund_id,r.intent_id)=(d.refund_id,d.intent_id)
        WHERE (d.intent_id,d.source_marker)=(intent,(owner->>'source_marker')::uuid);
    RETURN result;
END $$;

-- 原生付款和消费按「订单、付款处置、用户、批次」顺序取锁；历史付款以原交接行取得同一原订单的排他权。
CREATE FUNCTION meton_ledger.lock_refund_quote_target(owner jsonb,q meton_ledger.cash_refund_quotes) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE target bigint:=(q.request->>'order')::bigint; leased_credit uuid:=(q.snapshot->>'creditEvent')::uuid;
BEGIN
    IF q.request->>'cutoff' IS NULL THEN
        PERFORM FROM meton_ledger.cash_orders WHERE (native_order,source_marker)=(target,q.source_marker) FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'original cash order unavailable' USING ERRCODE='42501'; END IF;
        PERFORM FROM meton_ledger.cash_payment_dispositions d JOIN meton_ledger.cash_parts p USING(payment_id)
            WHERE (p.part_id,p.native_order,p.source_marker)=((q.request->>'part')::uuid,target,q.source_marker) FOR UPDATE OF d;
    ELSE
        PERFORM FROM meton_ledger.legacy_cash_handoffs h WHERE (h.cutoff,h.native_order,h.source_marker)=
            ((q.request->>'cutoff')::uuid,target,q.source_marker) FOR UPDATE;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'original refund funds unavailable' USING ERRCODE='42501'; END IF;
    PERFORM FROM public.users u JOIN public.meton_managed_creations m ON m.remote_user=u.id
        WHERE (m.source_marker,m.remote_user)=(q.source_marker,(owner->>'remote_user')::bigint) FOR SHARE OF m FOR UPDATE OF u;
    IF NOT FOUND THEN RAISE EXCEPTION 'original refund user unavailable' USING ERRCODE='42501'; END IF;
    IF leased_credit IS NOT NULL THEN
        PERFORM FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event
            WHERE l.credit_event=leased_credit AND e.source_marker=q.source_marker AND e.kind='purchase' FOR UPDATE OF l;
        IF NOT FOUND THEN RAISE EXCEPTION 'original purchase lot unavailable' USING ERRCODE='55000'; END IF;
    END IF;
END $$;

CREATE FUNCTION meton_ledger.confirm_original_refund(owner jsonb,actor jsonb,intent uuid,quote_ref uuid,expected_basis text,
    expected_fen bigint,until_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid:=(owner->>'source_marker')::uuid; generation bigint:=(owner->>'epoch')::bigint; prior meton_ledger.cash_refund_decisions;
    q meton_ledger.cash_refund_quotes; fresh jsonb; offer jsonb; result text; accepted uuid; purchase_units numeric; target bigint;
BEGIN
    PERFORM meton_ledger.require_cash_writer(owner->>'environment',owner->>'source',generation);
    IF current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') THEN
        RAISE EXCEPTION 'durable refund commit unavailable' USING ERRCODE='55000'; END IF;
    PERFORM meton_ledger.require_refund_actor(owner,actor,until_at);
    IF intent IS NULL OR quote_ref IS NULL OR intent='00000000-0000-0000-0000-000000000000'::uuid OR quote_ref='00000000-0000-0000-0000-000000000000'::uuid OR
        intent=quote_ref OR expected_basis IS NULL OR expected_basis !~ '^[0-9a-f]{64}$' OR expected_fen IS NULL OR expected_fen<=0 THEN
        RAISE EXCEPTION 'invalid refund confirmation' USING ERRCODE='22023'; END IF;
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(marker));
    PERFORM pg_advisory_xact_lock_shared(hashtextextended(marker::text||':'||((actor->>'session')::uuid)::text,0));
    PERFORM pg_advisory_xact_lock(hashtextextended('refund-intent/'||intent::text,0));
    SELECT * INTO prior FROM meton_ledger.cash_refund_decisions WHERE intent_id=intent;
    IF FOUND THEN
        IF prior.source_marker<>marker THEN RAISE EXCEPTION 'unknown refund intent' USING ERRCODE='42501'; END IF;
        IF (prior.quote_id,prior.basis_version,prior.confirmed_fen) IS DISTINCT FROM (quote_ref,expected_basis,expected_fen) THEN
            RAISE EXCEPTION 'refund intent parameters changed' USING ERRCODE='23505'; END IF;
        RETURN meton_ledger.read_original_refund_decision(owner,actor,intent,until_at);
    END IF;
    SELECT * INTO q FROM meton_ledger.cash_refund_quotes WHERE (quote_id,source_marker)=(quote_ref,marker);
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original refund quote' USING ERRCODE='42501'; END IF;
    IF q.outcome->>'basisVersion' IS DISTINCT FROM expected_basis OR q.outcome->>'state' IS DISTINCT FROM 'quoted'
        OR (q.outcome->>'fen')::bigint IS DISTINCT FROM expected_fen THEN
        RAISE EXCEPTION 'confirmation differs from original quote' USING ERRCODE='22023'; END IF;
    target:=(q.request->>'order')::bigint; purchase_units:=(q.request->>'units')::numeric;
    PERFORM meton_ledger.lock_refund_quote_target(owner,q);
    PERFORM meton_ledger.require_refund_actor(owner,actor,until_at);
    IF EXISTS(SELECT FROM meton_ledger.cash_refunds WHERE intent_id=intent) THEN
        -- 恢复或旧版本只剩退款、尚缺原确认凭证时，不补造一笔新的接受事实。
        IF NOT EXISTS(SELECT FROM meton_ledger.cash_refunds r LEFT JOIN meton_ledger.cash_parts p ON p.part_id=r.part_id
            LEFT JOIN meton_ledger.legacy_cash_handoffs h ON (h.cutoff,h.native_order)=(r.legacy_cutoff,r.native_order)
            WHERE r.intent_id=intent AND coalesce(p.source_marker,h.source_marker)=marker AND r.native_order=target) THEN
            RAISE EXCEPTION 'unknown refund intent' USING ERRCODE='42501'; END IF;
        RETURN jsonb_build_object('state','recovery_review','intent',intent,'quote',quote_ref);
    END IF;
    IF q.generation<>generation THEN result:='stale_quote';
    ELSIF q.expires_at<=clock_timestamp() THEN result:='expired';
    ELSIF EXISTS(SELECT FROM meton_ledger.cash_refund_decisions WHERE quote_id=quote_ref AND refund_id IS NOT NULL) THEN result:='quote_used';
    ELSE
        fresh:=meton_ledger.original_refund_snapshot(owner,target,(q.request->>'part')::uuid,(q.request->>'cutoff')::uuid,q.request->>'basis');
        offer:=meton_ledger.refund_offer(fresh,purchase_units,(q.request->>'fen')::bigint);
        IF fresh->>'state'<>'ready' THEN result:=fresh->>'state';
        ELSIF q.snapshot IS DISTINCT FROM fresh OR offer->>'state'<>'quoted' OR (offer->>'fen')::bigint IS DISTINCT FROM expected_fen THEN result:='stale_quote';
        ELSE result:='accepted'; END IF;
    END IF;
    IF result='accepted' THEN
        accepted:=meton_ledger.original_refund_id(marker,intent);
        IF purchase_units IS NOT NULL THEN
            UPDATE meton_ledger.lots SET refund_held=refund_held+purchase_units
                WHERE credit_event=(fresh->>'creditEvent')::uuid AND refundable AND remaining-held-refund_held>=purchase_units;
            IF NOT FOUND THEN RAISE EXCEPTION 'refund funds changed before acceptance' USING ERRCODE='40001'; END IF;
        ELSIF fresh->>'payment' IS NOT NULL THEN
            UPDATE meton_ledger.cash_payment_dispositions SET version=version+1 WHERE payment_id=(fresh->>'payment')::uuid
                AND version=(fresh->>'dispositionVersion')::bigint AND state='restricted';
            IF NOT FOUND THEN RAISE EXCEPTION 'unposted cash changed before acceptance' USING ERRCODE='40001'; END IF;
        END IF;
        INSERT INTO meton_ledger.cash_refunds(refund_id,intent_id,native_order,part_id,legacy_cutoff,basis,params_hash,
            expected_version,requested_fen,requested_units,phase) VALUES(accepted,intent,target,(q.request->>'part')::uuid,
            (q.request->>'cutoff')::uuid,q.request->>'basis',encode(sha256(convert_to(jsonb_build_array(marker,intent,quote_ref,expected_basis,expected_fen)::text,'UTF8')),'hex'),
            coalesce((fresh->>'dispositionVersion')::bigint,(fresh->>'refundCount')::bigint+1),expected_fen,purchase_units,'held');
    END IF;
    -- 锁等候耗尽报价／会话窗口时整笔撤回，不能留下只有退款占用或只有确认记录的半笔操作。
    PERFORM meton_ledger.require_refund_actor(owner,actor,until_at);
    IF result='accepted' AND q.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'refund quote expired before commit' USING ERRCODE='55000'; END IF;
    INSERT INTO meton_ledger.cash_refund_decisions(intent_id,source_marker,quote_id,basis_version,confirmed_fen,state,refund_id)
        VALUES(intent,marker,quote_ref,expected_basis,expected_fen,result,accepted);
    RETURN meton_ledger.read_original_refund_decision(owner,actor,intent,until_at);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.require_refund_actor(jsonb,jsonb,timestamptz),meton_ledger.original_refund_id(uuid,uuid),
    meton_ledger.lock_refund_quote_target(jsonb,meton_ledger.cash_refund_quotes),
    meton_ledger.read_original_refund_decision(jsonb,jsonb,uuid,timestamptz),
    meton_ledger.confirm_original_refund(jsonb,jsonb,uuid,uuid,text,bigint,timestamptz) FROM PUBLIC;
