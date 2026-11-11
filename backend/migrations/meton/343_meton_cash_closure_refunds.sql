-- 注销只增加原范围的自动受理权；金额、占用和现金执行继续使用原退款权威。
CREATE FUNCTION meton_ledger.reserve_original_refund(o jsonb,intent uuid,q meton_ledger.cash_refund_quotes,fresh jsonb,expected_fen bigint)
RETURNS uuid LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid:=(o->>'source_marker')::uuid; accepted uuid:=meton_ledger.original_refund_id(marker,intent);
    purchase_units numeric:=(q.request->>'units')::numeric; target bigint:=(q.request->>'order')::bigint;
BEGIN
    IF q.source_marker IS DISTINCT FROM marker OR q.snapshot IS DISTINCT FROM fresh OR fresh->>'state' IS DISTINCT FROM 'ready'
        OR (q.outcome->>'fen')::bigint IS DISTINCT FROM expected_fen OR q.outcome->>'state' IS DISTINCT FROM 'quoted' THEN
        RAISE EXCEPTION 'original refund reservation differs' USING ERRCODE='22023'; END IF;
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
        (q.request->>'cutoff')::uuid,q.request->>'basis',encode(sha256(convert_to(jsonb_build_array(marker,intent,q.quote_id,q.outcome->>'basisVersion',expected_fen)::text,'UTF8')),'hex'),
        coalesce((fresh->>'dispositionVersion')::bigint,(fresh->>'refundCount')::bigint+1),expected_fen,purchase_units,'held');
    RETURN accepted;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.reserve_original_refund(jsonb,uuid,meton_ledger.cash_refund_quotes,jsonb,bigint) FROM PUBLIC;

-- 普通会员确认和注销共用同一占用提交，原会员鉴权、报价复验与末次截止检查保持。
DO $reuse$
DECLARE body text:=pg_get_functiondef('meton_ledger.confirm_original_refund(jsonb,jsonb,uuid,uuid,text,bigint,timestamptz)'::regprocedure);
    first_at text:='    IF result=''accepted'' THEN'; last_at text:='    -- 锁等候耗尽报价／会话窗口'; first_pos int; last_pos int;
BEGIN
    IF cardinality(string_to_array(body,first_at))<>2 OR cardinality(string_to_array(body,last_at))<>2 THEN
        RAISE EXCEPTION 'original refund reservation changed'; END IF;
    first_pos:=strpos(body,first_at);last_pos:=strpos(body,last_at);
    IF last_pos<=first_pos THEN RAISE EXCEPTION 'original refund reservation order changed'; END IF;
    EXECUTE substring(body FROM 1 FOR first_pos-1)||
        '    IF result=''accepted'' THEN accepted:=meton_ledger.reserve_original_refund(owner,intent,q,fresh,expected_fen); END IF;'||E'\n'||
        substring(body FROM last_pos);
END $reuse$;

CREATE TABLE meton_ledger.cash_closure_refund_roles(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),actor name PRIMARY KEY,
    purpose text NOT NULL CHECK(purpose IN ('admit','stop','read'))
);
CREATE TABLE meton_ledger.cash_closure_refund_controls(
    closure_id uuid PRIMARY KEY REFERENCES meton_ledger.cash_closure_scopes,
    opened_at timestamptz,stopped_at timestamptz,stop_fact jsonb,stop_cut bigint,stop_count bigint,
    CHECK(opened_at IS NOT NULL OR stopped_at IS NOT NULL),
    CHECK(num_nonnulls(stopped_at,stop_fact,stop_cut,stop_count) IN (0,4)),
    CHECK(stop_cut>=0 AND stop_count>=0)
);
CREATE TABLE meton_ledger.cash_closure_refund_attempts(
    operation uuid PRIMARY KEY CHECK(operation<>'00000000-0000-0000-0000-000000000000'),
    sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
    closure_id uuid NOT NULL REFERENCES meton_ledger.cash_closure_refund_controls,
    request jsonb NOT NULL,receipt jsonb NOT NULL,quote_id uuid REFERENCES meton_ledger.cash_refund_quotes,
    refund_id uuid REFERENCES meton_ledger.cash_refunds,recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX cash_closure_attempts_page ON meton_ledger.cash_closure_refund_attempts(closure_id,sequence);
DO $protect$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['cash_closure_refund_roles','cash_closure_refund_attempts'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',t);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['cash_closure_refund_roles','cash_closure_refund_attempts','cash_closure_refund_controls'] LOOP
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',t);
    END LOOP;
END $protect$;
CREATE FUNCTION meton_ledger.protect_cash_closure_refund_stop() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF TG_OP<>'UPDATE' OR (NEW.closure_id,NEW.opened_at) IS DISTINCT FROM (OLD.closure_id,OLD.opened_at)
        OR OLD.stopped_at IS NOT NULL OR NEW.stopped_at IS NULL THEN
        RAISE EXCEPTION 'original closure stop cannot reopen' USING ERRCODE='55000'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER original_stop BEFORE UPDATE OR DELETE ON meton_ledger.cash_closure_refund_controls
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.protect_cash_closure_refund_stop();
ALTER TABLE meton_ledger.cash_closure_refund_controls ENABLE ALWAYS TRIGGER original_stop;

/** 三种独立权限不能兼任普通会员退款；恢复换代和原归属每次复验。 */
CREATE FUNCTION meton_ledger.require_cash_closure_refund_actor(o jsonb,purpose_name text) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR NOT EXISTS(
        SELECT FROM meton_ledger.cash_closure_refund_roles r WHERE
        (r.deployment,r.source,r.epoch,r.actor,r.purpose)=
            (o->>'environment',o->>'source',(o->>'epoch')::bigint,session_user::name,purpose_name)) THEN
        RAISE EXCEPTION 'current original closure purpose required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_refund_owner(o);
    IF pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_ledger','CREATE')
        OR EXISTS(SELECT FROM pg_roles r WHERE (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR
            r.rolname IN ('pg_write_all_data','pg_execute_server_program','pg_read_server_files','pg_write_server_files'))
            AND pg_has_role(session_user,r.oid,'MEMBER'))
        OR EXISTS(SELECT FROM pg_class t WHERE t.relkind IN ('r','p') AND (t.relnamespace='meton_ledger'::regnamespace OR t.oid IN
            ('public.users'::regclass,'public.payment_orders'::regclass,'public.meton_managed_fence'::regclass,'public.meton_managed_creations'::regclass))
            AND (has_any_column_privilege(session_user,t.oid,'INSERT,UPDATE') OR has_table_privilege(session_user,t.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted original closure role required' USING ERRCODE='42501'; END IF;
    IF purpose_name<>'read' AND (current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
        OR current_setting('synchronous_commit') NOT IN ('on','remote_apply')) THEN
        RAISE EXCEPTION 'durable original closure commit unavailable' USING ERRCODE='55000'; END IF;
END $$;

/** 这里只认 Identity 已提交的原决定。原范围绑定回执或仍 prepared 的确认都不能授权退款。 */
CREATE FUNCTION meton_ledger.require_cash_closure_decision(o jsonb,s meton_ledger.cash_closure_scopes,fact jsonb,decision text,until_at timestamptz)
RETURNS void LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF until_at IS NULL OR until_at<=clock_timestamp() OR until_at>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'original closure identity window expired' USING ERRCODE='55000'; END IF;
    IF (jsonb_typeof(fact)='object' AND fact ?& ARRAY['closure','registration','decision','lifecycle','securityVersion','recoveryVersion','lastStopVersion']
        AND fact-ARRAY['closure','registration','decision','lifecycle','securityVersion','recoveryVersion','lastStopVersion']='{}'::jsonb
        AND (fact->>'closure')::uuid=s.closure_id AND (fact->>'registration')::uuid=s.registration AND fact->>'decision'=decision
        AND (fact->>'securityVersion')::bigint>=(s.identity_fact->>'securityVersion')::bigint+1
        AND (fact->>'recoveryVersion')::bigint>=(s.identity_fact->>'recoveryVersion')::bigint
        AND (fact->>'lastStopVersion')::bigint>=(s.identity_fact->>'securityVersion')::bigint+1
        AND (fact->>'lastStopVersion')::bigint<=(fact->>'securityVersion')::bigint) IS NOT TRUE THEN
        RAISE EXCEPTION 'committed original closure decision required' USING ERRCODE='42501'; END IF;
    IF decision='closing' THEN
        IF fact->>'lifecycle' IS DISTINCT FROM 'closing' OR (fact->>'securityVersion')::bigint<>(s.identity_fact->>'securityVersion')::bigint+1
            OR (fact->>'recoveryVersion')::bigint<>(s.identity_fact->>'recoveryVersion')::bigint OR NOT EXISTS(
            SELECT FROM meton_ledger.cash_account_facts f JOIN public.users u ON u.id=(o->>'remote_user')::bigint WHERE
            (f.source_marker,f.registration,f.user_id,f.account_id,f.creation,f.projection_epoch)=
                ((o->>'source_marker')::uuid,s.registration,(o->>'user')::uuid,(o->>'account')::uuid,(o->>'creation')::uuid,(o->>'epoch')::bigint)
            AND (f.lifecycle,f.security_version,f.recovery_version,f.last_stop_version)=
                ('closing',(fact->>'securityVersion')::bigint,(fact->>'recoveryVersion')::bigint,(fact->>'lastStopVersion')::bigint)
            AND f.preparing_closure IS NULL AND u.role='user' AND u.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'current original closure execution unavailable' USING ERRCODE='42501'; END IF;
    ELSIF decision<>'withdrawn' OR (fact->>'lifecycle' IN ('security_recovery','active')) IS NOT TRUE THEN
        RAISE EXCEPTION 'original withdrawal decision required' USING ERRCODE='42501';
    END IF;
END $$;

/** 来源返回固定停止截点；Identity 撤回本身不等同于已经取得这个回执。 */
CREATE FUNCTION meton_ledger.cash_closure_refund_control_view(p_closure uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('closure',closure_id,'state',CASE WHEN stopped_at IS NULL THEN 'running' ELSE 'stopped' END,
        'openedAt',opened_at,'stoppedAt',stopped_at,'cut',stop_cut,'count',stop_count)
    FROM meton_ledger.cash_closure_refund_controls WHERE closure_id=p_closure
$$;

CREATE FUNCTION meton_ledger.read_cash_closure_refunds(o jsonb,p_closure uuid,p_registration uuid,p_scope text,after_sequence bigint,page_size int)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE control jsonb; cut bigint; page jsonb;
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'read');
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration
        AND receipt->>'scopeHash'=p_scope) THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    IF after_sequence IS NULL OR after_sequence<0 OR page_size IS NULL OR page_size NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'bounded closure refund page required' USING ERRCODE='22023'; END IF;
    control:=meton_ledger.cash_closure_refund_control_view(p_closure);
    IF control IS NULL THEN RETURN NULL; END IF;
    cut:=coalesce((control->>'cut')::bigint,(SELECT coalesce(max(sequence),0) FROM meton_ledger.cash_closure_refund_attempts WHERE closure_id=p_closure));
    SELECT coalesce(jsonb_agg(jsonb_build_object('sequence',a.sequence,'operation',a.operation,'receipt',a.receipt,
        'refundPhase',r.phase,'refundVersion',r.disposition_version) ORDER BY a.sequence),'[]'::jsonb) INTO page
        FROM (SELECT * FROM meton_ledger.cash_closure_refund_attempts WHERE closure_id=p_closure AND sequence>after_sequence AND sequence<=cut
            ORDER BY sequence LIMIT page_size) a LEFT JOIN meton_ledger.cash_refunds r ON r.refund_id=a.refund_id;
    RETURN jsonb_build_object('control',control,'cut',cut,'after',after_sequence,'items',page,
        'hasMore',EXISTS(SELECT FROM meton_ledger.cash_closure_refund_attempts WHERE closure_id=p_closure AND sequence<=cut AND
            sequence>coalesce((page->-1->>'sequence')::bigint,after_sequence)));
END $$;

CREATE FUNCTION meton_ledger.stop_cash_closure_refunds(o jsonb,p_closure uuid,p_registration uuid,p_scope text,fact jsonb,until_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s meton_ledger.cash_closure_scopes; c meton_ledger.cash_closure_refund_controls; cut bigint; total bigint;
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'stop');
    PERFORM meton_ledger.require_cash_writer(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    SELECT * INTO s FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration AND receipt->>'scopeHash'=p_scope;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'withdrawn',until_at);
    -- 只锁这次原范围。现金工作者不取这把锁，停止不取消已受理退款或其他账号的任务。
    PERFORM pg_advisory_xact_lock(hashtextextended('cash-closure-refunds/'||p_closure::text,0));
    SELECT * INTO c FROM meton_ledger.cash_closure_refund_controls WHERE closure_id=p_closure FOR UPDATE;
    IF FOUND AND c.stopped_at IS NOT NULL THEN RETURN meton_ledger.cash_closure_refund_control_view(p_closure); END IF;
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'withdrawn',until_at);
    SELECT coalesce(max(sequence),0),count(*) INTO cut,total FROM meton_ledger.cash_closure_refund_attempts WHERE closure_id=p_closure;
    INSERT INTO meton_ledger.cash_closure_refund_controls(closure_id,stopped_at,stop_fact,stop_cut,stop_count)
        VALUES(p_closure,clock_timestamp(),fact,cut,total) ON CONFLICT(closure_id) DO UPDATE SET
        stopped_at=excluded.stopped_at,stop_fact=excluded.stop_fact,stop_cut=excluded.stop_cut,stop_count=excluded.stop_count;
    RETURN meton_ledger.cash_closure_refund_control_view(p_closure);
END $$;

/** 每个受理操作只计算一次；同单未决退款直接关联，后续释放／纠正必须使用新的原操作重新核对。 */
CREATE FUNCTION meton_ledger.admit_cash_closure_refund(o jsonb,p_closure uuid,p_registration uuid,p_scope text,fact jsonb,
    operation uuid,order_id bigint,part_ref uuid,cutoff_ref uuid,basis_name text,until_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s meton_ledger.cash_closure_scopes; prior meton_ledger.cash_closure_refund_attempts; selected jsonb; request jsonb; fresh jsonb;
    q meton_ledger.cash_refund_quotes; quoted jsonb; offer jsonb; outcome jsonb; units numeric; fen bigint; original uuid; quote_ref uuid;
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'admit');
    PERFORM meton_ledger.require_cash_writer(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    SELECT * INTO s FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration AND receipt->>'scopeHash'=p_scope;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    IF operation IS NULL OR operation='00000000-0000-0000-0000-000000000000' OR order_id IS NULL OR order_id<=0 OR num_nonnulls(part_ref,cutoff_ref)<>1
        OR basis_name IS NULL OR basis_name NOT IN ('purchased_source','unposted_cash') THEN
        RAISE EXCEPTION 'original refund selection required' USING ERRCODE='22023'; END IF;
    request:=jsonb_build_object('closure',p_closure,'order',order_id,'part',part_ref,'cutoff',cutoff_ref,'basis',basis_name);
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((o->>'source_marker')::uuid));
    PERFORM pg_advisory_xact_lock(hashtextextended('cash-closure-refunds/'||p_closure::text,0));
    PERFORM pg_advisory_xact_lock(hashtextextended('refund-intent/'||operation::text,0));
    SELECT * INTO prior FROM meton_ledger.cash_closure_refund_attempts a WHERE a.operation=admit_cash_closure_refund.operation;
    IF FOUND THEN
        IF prior.closure_id<>p_closure OR prior.request<>request THEN RAISE EXCEPTION 'original closure refund differs' USING ERRCODE='23505'; END IF;
        RETURN prior.receipt;
    END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_closure_refund_controls WHERE closure_id=p_closure AND stopped_at IS NOT NULL) THEN
        RETURN jsonb_build_object('state','stopped','closure',p_closure,'operation',operation); END IF;
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closing',until_at);
    -- 已确认原订单的迟到现金仍属同一范围；不得把检查之后新建的订单或别人的款项自动加入。
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_closure_snapshots snap,jsonb_array_elements(snap.items) item WHERE snap.snapshot_id=s.snapshot_id AND
        ((cutoff_ref IS NULL AND item->>'kind'='order' AND item->>'ref'=order_id::text) OR
         (cutoff_ref IS NOT NULL AND item->>'kind'='legacy_order' AND item->>'ref'=cutoff_ref::text||'/'||order_id::text))) THEN
        RAISE EXCEPTION 'refund outside confirmed original orders' USING ERRCODE='42501'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_refund_decisions WHERE intent_id=operation) OR EXISTS(SELECT FROM meton_ledger.cash_refunds WHERE intent_id=operation) THEN
        RAISE EXCEPTION 'refund intent belongs to another original operation' USING ERRCODE='23505'; END IF;
    INSERT INTO meton_ledger.cash_closure_refund_controls(closure_id,opened_at) VALUES(p_closure,clock_timestamp()) ON CONFLICT DO NOTHING;
    -- 原锁顺序和原比例完全复用；取得锁后再读来源，不能按快照中的旧可退金额占款。
    q.source_marker:=(o->>'source_marker')::uuid;
    q.request:=jsonb_build_object('order',order_id,'part',part_ref,'cutoff',cutoff_ref,'basis',basis_name);
    q.snapshot:=meton_ledger.original_refund_snapshot(o,order_id,part_ref,cutoff_ref,basis_name);
    PERFORM meton_ledger.lock_refund_quote_target(o,q);
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closing',until_at);
    selected:=meton_ledger.closure_refund_basis(o,order_id,part_ref,cutoff_ref,basis_name);
    fresh:=selected->'snapshot';offer:=selected->'offer';
    IF fresh->>'state'='refund_pending' THEN
        SELECT refund_id INTO original FROM meton_ledger.cash_refunds WHERE native_order=order_id AND phase NOT IN ('released','settled')
            ORDER BY refund_id LIMIT 1;
        outcome:=jsonb_build_object('state',CASE WHEN original IS NULL THEN 'recheck_required' ELSE 'existing_refund' END,'refund',original);
    ELSIF fresh->>'state'<>'ready' THEN outcome:=jsonb_build_object('state',fresh->>'state');
    ELSIF offer->>'state'<>'quoted' THEN outcome:=jsonb_build_object('state',offer->>'state');
    ELSE
        fen:=(offer->>'fen')::bigint;units:=(offer->>'units')::numeric;
        quote_ref:=meton_ledger.original_refund_id(p_closure,operation);
        quoted:=meton_ledger.quote_original_refund(o,quote_ref,order_id,part_ref,cutoff_ref,basis_name,
            CASE WHEN units IS NOT NULL THEN units::numeric(20,8)::text END,CASE WHEN units IS NULL THEN fen END,until_at);
        SELECT * INTO STRICT q FROM meton_ledger.cash_refund_quotes WHERE quote_id=quote_ref;
        IF q.snapshot IS DISTINCT FROM fresh OR quoted->>'state'<>'quoted' OR (quoted->>'fen')::bigint<>fen THEN
            RAISE EXCEPTION 'original closure refund changed during admission' USING ERRCODE='40001'; END IF;
        original:=meton_ledger.reserve_original_refund(o,operation,q,fresh,fen);
        INSERT INTO meton_ledger.cash_refund_decisions(intent_id,source_marker,quote_id,basis_version,confirmed_fen,state,refund_id)
            VALUES(operation,q.source_marker,q.quote_id,q.outcome->>'basisVersion',fen,'accepted',original);
        outcome:=jsonb_build_object('state','accepted','refund',original,'quote',quote_ref,'fen',fen,'units',units::text);
    END IF;
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closing',until_at);
    outcome:=outcome||jsonb_build_object('closure',p_closure,'operation',operation,'order',order_id,'part',part_ref,'cutoff',cutoff_ref,'basis',basis_name);
    INSERT INTO meton_ledger.cash_closure_refund_attempts(operation,closure_id,request,receipt,quote_id,refund_id)
        VALUES(operation,p_closure,request,outcome,quote_ref,original);
    RETURN outcome;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.protect_cash_closure_refund_stop(),meton_ledger.require_cash_closure_refund_actor(jsonb,text),
    meton_ledger.require_cash_closure_decision(jsonb,meton_ledger.cash_closure_scopes,jsonb,text,timestamptz),
    meton_ledger.cash_closure_refund_control_view(uuid),meton_ledger.read_cash_closure_refunds(jsonb,uuid,uuid,text,bigint,int),
    meton_ledger.stop_cash_closure_refunds(jsonb,uuid,uuid,text,jsonb,timestamptz),
    meton_ledger.admit_cash_closure_refund(jsonb,uuid,uuid,text,jsonb,uuid,bigint,uuid,uuid,text,timestamptz) FROM PUBLIC;
