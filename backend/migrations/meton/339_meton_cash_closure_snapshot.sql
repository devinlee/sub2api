-- 注销预查保存同一语句时点的只读材料。它不是新钱包、退款申请或最终关闭证明。
CREATE TABLE meton_ledger.cash_closure_readers(
    deployment text NOT NULL, source text NOT NULL, epoch bigint NOT NULL CHECK(epoch>0), reader name NOT NULL UNIQUE,
    PRIMARY KEY(deployment,source,epoch,reader)
);
CREATE TABLE meton_ledger.cash_closure_snapshots(
    snapshot_id uuid PRIMARY KEY CHECK(snapshot_id<>'00000000-0000-0000-0000-000000000000'),
    owner jsonb NOT NULL, registration uuid NOT NULL, identity_fact jsonb NOT NULL,
    captured_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
    header jsonb NOT NULL, items jsonb NOT NULL CHECK(jsonb_typeof(items)='array'),
    CHECK(isfinite(captured_at) AND isfinite(expires_at) AND expires_at>captured_at)
);
DO $protect$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['cash_closure_readers','cash_closure_snapshots'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',t);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',t);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',t);
    END LOOP;
END $protect$;

/** 每页均复验当前原账号和读取角色；持有快照编号不能绕过恢复换代或 Identity 状态变化。 */
CREATE FUNCTION meton_ledger.require_cash_closure_reader(o jsonb,registration_id uuid,identity_state jsonb) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR
        NOT EXISTS(SELECT FROM meton_ledger.cash_closure_readers r WHERE
            (r.deployment,r.source,r.epoch,r.reader)=(o->>'environment',o->>'source',(o->>'epoch')::bigint,session_user::name)) THEN
        RAISE EXCEPTION 'current closure reader required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_refund_owner(o);
    IF (jsonb_typeof(identity_state)='object' AND identity_state ?& ARRAY['lifecycle','securityVersion','recoveryVersion','lastStopVersion']
        AND identity_state-ARRAY['lifecycle','securityVersion','recoveryVersion','lastStopVersion']='{}'::jsonb
        AND identity_state->>'lifecycle'='active') IS NOT TRUE THEN
        RAISE EXCEPTION 'original closure identity required' USING ERRCODE='22023'; END IF;
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_account_facts f JOIN public.users u ON u.id=(o->>'remote_user')::bigint
        WHERE (f.source_marker,f.registration,f.user_id,f.account_id,f.creation,f.projection_epoch)=
            ((o->>'source_marker')::uuid,registration_id,(o->>'user')::uuid,(o->>'account')::uuid,(o->>'creation')::uuid,(o->>'epoch')::bigint)
        AND (f.lifecycle,f.security_version,f.recovery_version,f.last_stop_version)=
            (identity_state->>'lifecycle',(identity_state->>'securityVersion')::bigint,(identity_state->>'recoveryVersion')::bigint,
                (identity_state->>'lastStopVersion')::bigint)
        AND u.status='active' AND u.deleted_at IS NULL AND u.role='user' AND u.restrict_public_groups
        AND u.password_hash='!meton-managed' AND u.email='meton-'||(o->>'account')||'@managed.invalid') THEN
        RAISE EXCEPTION 'original closure identity changed' USING ERRCODE='42501'; END IF;
END $$;

/** 使用原退款算法给出可核对的分类；没有原比例、原付款或原终态时保留待核对，不按余额猜退款金额。 */
CREATE FUNCTION meton_ledger.closure_refund_basis(o jsonb,ord bigint,part uuid,cut uuid,basis text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE s jsonb; offer jsonb; units numeric; fen bigint;
BEGIN
    s:=meton_ledger.original_refund_snapshot(o,ord,part,cut,basis);
    IF s->>'state'='ready' THEN
        IF basis='purchased_source' THEN units:=(s->>'availableUnits')::numeric;
        ELSE fen:=least((s->>'faceFen')::numeric-(s->>'partReturnedFen')::numeric,
            (s->>'paymentCapFen')::numeric-(s->>'paymentReturnedFen')::numeric)::bigint; END IF;
        offer:=meton_ledger.refund_offer(s,units,fen);
    END IF;
    RETURN jsonb_build_object('order',ord,'part',part,'cutoff',cut,'basis',basis,'snapshot',s,'offer',offer);
END $$;

/** 所有查询都在调用语句的同一快照内；H、R 和尚未入账的现金不能通过资金序号的分页被遗漏。 */
CREATE FUNCTION meton_ledger.cash_closure_inventory(o jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE target_marker uuid:=(o->>'source_marker')::uuid; remote_id bigint:=(o->>'remote_user')::bigint;
    statement jsonb; lines jsonb; digest text; counts jsonb;
BEGIN
    statement:=meton_ledger.open_statement(o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'user')::uuid,
        (o->>'account')::uuid,(o->>'creation')::uuid,(o->>'dispatch')::uuid,remote_id,target_marker,
        (statement_timestamp() AT TIME ZONE 'UTC')::date,(statement_timestamp() AT TIME ZONE 'UTC')::date);
    -- 原历史截点尚未完整交接时，不能凭本次已看到的部分订单签发完整快照。
    IF EXISTS(SELECT FROM meton_ledger.legacy_balance_fences f JOIN meton_ledger.legacy_cash_facts c USING(cutoff)
        WHERE f.source_marker=target_marker AND c.kind='order' AND NOT EXISTS(SELECT FROM meton_ledger.legacy_cash_handoffs h
            WHERE (h.cutoff,h.source_marker,h.native_order)=(f.cutoff,target_marker,c.native_id))) THEN
        RAISE EXCEPTION 'historical closure inventory incomplete' USING ERRCODE='55000'; END IF;
    WITH inventory(kind,ref,value) AS (
        SELECT 'source',e.event_id::text,jsonb_build_object('category',CASE WHEN e.kind='grant' THEN 'gift'
            WHEN meton_ledger.cash_purchase_needs_review(e.event_id) THEN 'disputed_purchase' ELSE 'purchase' END,
            'kind',e.kind,'sequence',e.sequence,'remaining',l.remaining::text,'held',l.held::text,'refundHeld',l.refund_held::text,
            'available',(l.remaining-l.held-l.refund_held)::numeric(20,8)::text,'refundable',l.refundable)
        FROM meton_ledger.events e JOIN meton_ledger.lots l ON l.credit_event=e.event_id WHERE e.source_marker=target_marker
        UNION ALL
        SELECT 'registration',target_marker::text,jsonb_build_object('category','gift_qualification','state',
            CASE WHEN g.event_id IS NULL THEN 'not_recorded_not_proof_of_eligibility' ELSE 'recorded' END,
            'eligibility',g.eligibility,'event',g.event_id,'termination',t.decision)
        FROM (SELECT 1) singleton LEFT JOIN meton_ledger.registration_grants g ON g.source_marker=target_marker
            LEFT JOIN meton_ledger.gift_terminations t ON t.source_marker=target_marker
        UNION ALL
        SELECT 'order',c.native_order::text,jsonb_build_object('category',CASE WHEN a.dispatch_id IS NULL AND stop.phase IS DISTINCT FROM 'closed_local'
            THEN 'unpaid_not_sent' WHEN stop.phase IN ('closed_local','closed_channel') THEN 'closed_order'
            WHEN EXISTS(SELECT FROM meton_ledger.cash_payments p WHERE p.native_order=c.native_order) THEN 'payment_recorded'
            ELSE 'payment_inflight_unknown' END,'intent',c.intent_id,'attempt',a.attempt_id,'dispatch',a.dispatch_id,
            'closeState',stop.phase,'closeVersion',stop.version,'cashReview',meton_ledger.original_cash_review(c))
        FROM meton_ledger.cash_orders c LEFT JOIN meton_ledger.cash_order_attempts a USING(native_order)
            LEFT JOIN meton_ledger.cash_order_stops stop USING(native_order) WHERE c.source_marker=target_marker
        UNION ALL
        SELECT 'payment',p.payment_id::text,jsonb_build_object('category',CASE WHEN d.state='resolved' THEN 'payment_allocated'
            WHEN d.state='restricted' THEN 'paid_restricted' ELSE 'paid_unposted' END,'order',p.native_order,'state',d.state,'version',d.version,
            'currency',p.payer_currency,'payerFen',p.payer_fen::text,'orderFen',p.order_fen::text)
        FROM meton_ledger.cash_payments p JOIN meton_ledger.cash_payment_dispositions d USING(payment_id) WHERE p.source_marker=target_marker
        UNION ALL
        SELECT 'cash_basis',p.part_id::text,meton_ledger.closure_refund_basis(o,p.native_order,p.part_id,NULL,p.basis)
            ||jsonb_build_object('category',p.basis,'payment',p.payment_id,'credit',p.credit_event)
        FROM meton_ledger.cash_parts p WHERE p.source_marker=target_marker
        UNION ALL
        SELECT 'legacy_order',h.cutoff::text||'/'||h.native_order::text,
            meton_ledger.read_legacy_cash_order(o,h.cutoff,h.native_order)||jsonb_build_object('category','historical_cash')
        FROM meton_ledger.legacy_cash_handoffs h WHERE h.source_marker=target_marker
        UNION ALL
        SELECT 'legacy_activity',a.cutoff::text||'/'||a.kind||'/'||a.native_ref,
            jsonb_build_object('category','historical_activity_review','kind',a.kind,'original',a.native_ref,'proof',a.proof)
        FROM meton_ledger.legacy_activity_facts a JOIN meton_ledger.legacy_balance_fences f USING(cutoff) WHERE f.source_marker=target_marker
        UNION ALL
        SELECT 'legacy_refund_audit',a.cutoff::text||'/'||a.native_id::text,
            jsonb_build_object('category','historical_refund_review','order',h.native_order,'action',a.proof->>'action',
                'evidenceHash',a.proof->>'detail_digest','originalDeduction',CASE WHEN a.proof->>'action'='REFUND_PENDING'
                THEN meton_ledger.legacy_pending_deduction(a.proof->>'detail_digest',l.detail) END)
        FROM meton_ledger.legacy_cash_handoffs h JOIN meton_ledger.legacy_cash_facts a ON a.cutoff=h.cutoff
            AND a.kind='order_audit' AND a.proof->>'order_id'=h.native_order::text
            LEFT JOIN public.payment_audit_logs l ON l.id=a.native_id AND l.order_id=h.native_order::text
        WHERE h.source_marker=target_marker AND a.proof->>'action' LIKE 'REFUND%'
        UNION ALL
        SELECT 'legacy_basis',h.cutoff::text||'/'||h.native_order::text,
            meton_ledger.closure_refund_basis(o,h.native_order,NULL,h.cutoff,v.value->>'basis')||jsonb_build_object('category',v.value->>'basis')
        FROM meton_ledger.legacy_cash_handoffs h CROSS JOIN LATERAL (SELECT meton_ledger.read_legacy_cash_order(o,h.cutoff,h.native_order) AS value) v
        WHERE h.source_marker=target_marker AND v.value->>'basis' IN ('purchased_source','unposted_cash')
        UNION ALL
        SELECT 'unmapped_order',p.id::text,jsonb_build_object('category','unknown_original_cash','state',p.status)
        FROM public.payment_orders p WHERE p.user_id=remote_id
            AND NOT EXISTS(SELECT FROM meton_ledger.cash_orders c WHERE c.native_order=p.id AND c.source_marker=target_marker)
            AND NOT EXISTS(SELECT FROM meton_ledger.legacy_cash_handoffs h WHERE h.native_order=p.id AND h.source_marker=target_marker)
        UNION ALL
        SELECT 'refund',r.refund_id::text,jsonb_build_object('category',CASE WHEN confirmation.refund IS NOT NULL AND posting.refund IS NULL
            THEN 'paid_awaiting_settlement' WHEN r.phase IN ('possibly_sent','unknown','review') THEN 'refund_unknown'
            WHEN r.phase IN ('held','cash_confirmed') THEN 'refund_held' ELSE 'refund_terminal' END,
            'order',r.native_order,'part',r.part_id,'cutoff',r.legacy_cutoff,'basis',r.basis,'phase',r.phase,'version',r.disposition_version,
            'fen',r.requested_fen::text,'units',r.requested_units::text,'cashConfirmed',confirmation.refund IS NOT NULL,
            'sourceSettled',posting.refund IS NOT NULL,'recoveryConfirmed',recovery.refund_id IS NOT NULL)
        FROM meton_ledger.cash_refunds r LEFT JOIN meton_ledger.refund_cash_confirmations confirmation ON confirmation.refund=r.refund_id
            LEFT JOIN meton_ledger.refund_cash_postings posting ON posting.refund=r.refund_id
            LEFT JOIN meton_ledger.cash_refund_recoveries recovery USING(refund_id)
        WHERE EXISTS(SELECT FROM meton_ledger.cash_orders c WHERE c.native_order=r.native_order AND c.source_marker=target_marker)
            OR EXISTS(SELECT FROM meton_ledger.legacy_cash_handoffs h WHERE (h.native_order,h.cutoff,h.source_marker)=(r.native_order,r.legacy_cutoff,target_marker))
        UNION ALL
        SELECT 'model',r.request_id::text,jsonb_build_object('category',CASE WHEN ending.request_id IS NULL AND d.state IS DISTINCT FROM 'cancelled_unsent'
            THEN 'model_unsettled' WHEN coalesce(f.gap,0)>0 THEN 'model_shortfall' ELSE 'model_terminal' END,
            'operation',r.operation_id,'caller',r.caller,'sendState',d.state,'quote',r.quote::text,'uncovered',coalesce(f.gap,0)::numeric(20,8)::text,
            'execution',c.observation->>'execution','feeReady',c.observation->'fee_ready')
        FROM meton_ledger.text_requests r LEFT JOIN meton_ledger.text_send_decisions d USING(request_id)
            LEFT JOIN meton_ledger.text_fee_endings ending USING(request_id) LEFT JOIN meton_ledger.text_completions c USING(request_id)
            LEFT JOIN LATERAL (SELECT sum(fee.uncovered) AS gap FROM meton_ledger.latest_text_fees fee WHERE fee.request_id=r.request_id) f ON true
        WHERE r.source_marker=target_marker
        UNION ALL
        SELECT 'cash_review',coalesce(r.refund::text,'original')||'/'||encode(r.evidence,'hex'),jsonb_build_object('category','cash_dispute','refund',r.refund,'payment',r.payment,
            'cutoff',r.cutoff,'order',r.original_order,'credit',r.legacy_credit,'exposure',r.snapshot)
        FROM meton_ledger.cash_return_reviews r WHERE r.marker=target_marker
        UNION ALL
        SELECT 'dispute',s.dispute::text,jsonb_build_object('category','cash_dispute','order',s.native_order,'revision',s.revision,'value',s.value)
        FROM meton_ledger.cash_dispute_statuses s WHERE s.marker=target_marker
            AND NOT EXISTS(SELECT FROM meton_ledger.cash_dispute_statuses newer WHERE newer.dispute=s.dispute AND newer.revision>s.revision)
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('kind',kind,'ref',ref,'value',value) ORDER BY kind COLLATE "C",ref COLLATE "C"),'[]'::jsonb)
        INTO lines FROM inventory;
    IF (SELECT count(*) FROM jsonb_array_elements(lines))<>(SELECT count(DISTINCT jsonb_build_array(x->>'kind',x->>'ref')) FROM jsonb_array_elements(lines) x) THEN
        RAISE EXCEPTION 'ambiguous closure inventory identity' USING ERRCODE='55000'; END IF;
    SELECT jsonb_object_agg(category,n) INTO counts FROM (
        SELECT x#>>'{value,category}' AS category,count(*) AS n FROM jsonb_array_elements(lines) x GROUP BY 1) c;
    digest:=encode(sha256(convert_to(jsonb_build_object('funds',statement->'funds','cut',(statement->'cut')-'observed_at','items',lines)::text,'UTF8')),'hex');
    RETURN jsonb_build_object('format',1,'funds',statement->'funds','cut',statement->'cut','inventoryHash',digest,
        'count',jsonb_array_length(lines),'categories',counts,'items',lines,'meaning','inspection_only_not_settled');
END $$;

/** 同一操作提交后丢响应仍取原快照；重新检查必须用新编号，不能在同一编号下悄悄更新确认范围。 */
CREATE FUNCTION meton_ledger.open_cash_closure_snapshot(o jsonb,original uuid,registration_id uuid,identity_state jsonb,until_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE previous meton_ledger.cash_closure_snapshots; captured jsonb; now_at timestamptz;
BEGIN
    PERFORM meton_ledger.require_cash_writer(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    -- 与原生命周期投递共用账号锁。等待其他节点限制账号之后，必须重读当前事实再采集，不能沿等待前的 active 快照。
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((o->>'source_marker')::uuid));
    PERFORM meton_ledger.require_cash_closure_reader(o,registration_id,identity_state);
    IF original IS NULL OR original='00000000-0000-0000-0000-000000000000' THEN
        RAISE EXCEPTION 'closure snapshot id required' USING ERRCODE='22023'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('cash-closure-snapshot/'||original::text,0));
    SELECT * INTO previous FROM meton_ledger.cash_closure_snapshots WHERE snapshot_id=original;
    IF FOUND THEN
        IF previous.owner IS DISTINCT FROM o OR previous.registration IS DISTINCT FROM registration_id THEN
            RAISE EXCEPTION 'unknown original closure snapshot' USING ERRCODE='42501'; END IF;
        IF previous.identity_fact IS DISTINCT FROM identity_state THEN RAISE EXCEPTION 'closure identity differs' USING ERRCODE='23505'; END IF;
        IF previous.expires_at<=clock_timestamp() THEN RETURN jsonb_build_object('state','expired','snapshot',original); END IF;
        RETURN previous.header;
    END IF;
    now_at:=clock_timestamp();
    IF until_at IS NULL OR NOT isfinite(until_at) OR until_at<=now_at OR until_at>now_at+interval '5 minutes' THEN
        RAISE EXCEPTION 'invalid closure inspection window' USING ERRCODE='22023'; END IF;
    captured:=meton_ledger.cash_closure_inventory(o);
    -- 读取或等待越过截止时不留下可供确认的残缺快照。
    IF until_at<=clock_timestamp() THEN RAISE EXCEPTION 'closure inspection expired' USING ERRCODE='55000'; END IF;
    previous.header:=(captured-'items')||jsonb_build_object('state','observed','snapshot',original,'origin',o,
        'registration',registration_id,'identity',identity_state,'expiresAt',until_at);
    INSERT INTO meton_ledger.cash_closure_snapshots VALUES(original,o,registration_id,identity_state,now_at,until_at,previous.header,captured->'items');
    RETURN previous.header;
END $$;

/** 分页只读已固定的内容。最后一页并不证明此前每页已被客户端读取，调用方须核对总数和全量摘要。 */
CREATE FUNCTION meton_ledger.read_cash_closure_snapshot(o jsonb,original uuid,registration_id uuid,identity_state jsonb,after_item integer,page_size integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE saved meton_ledger.cash_closure_snapshots; page jsonb; last_item integer;
BEGIN
    PERFORM meton_ledger.require_cash_closure_reader(o,registration_id,identity_state);
    IF (after_item>=0 AND page_size BETWEEN 1 AND 100) IS NOT TRUE THEN RAISE EXCEPTION 'invalid closure page' USING ERRCODE='22023'; END IF;
    SELECT * INTO saved FROM meton_ledger.cash_closure_snapshots WHERE snapshot_id=original AND owner=o AND registration=registration_id AND identity_fact=identity_state;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF saved.expires_at<=statement_timestamp() THEN RETURN jsonb_build_object('state','expired','snapshot',original); END IF;
    IF after_item>jsonb_array_length(saved.items) THEN RAISE EXCEPTION 'closure page past cutoff' USING ERRCODE='22023'; END IF;
    SELECT coalesce(jsonb_agg(v||jsonb_build_object('ordinal',n) ORDER BY n),'[]'::jsonb),coalesce(max(n),after_item)
        INTO page,last_item FROM jsonb_array_elements(saved.items) WITH ORDINALITY x(v,n) WHERE n>after_item AND n<=after_item+page_size;
    RETURN saved.header||jsonb_build_object('after',after_item,'next',last_item,'more',last_item<jsonb_array_length(saved.items),'items',page);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.require_cash_closure_reader(jsonb,uuid,jsonb),meton_ledger.closure_refund_basis(jsonb,bigint,uuid,uuid,text),
    meton_ledger.cash_closure_inventory(jsonb),meton_ledger.open_cash_closure_snapshot(jsonb,uuid,uuid,jsonb,timestamptz),
    meton_ledger.read_cash_closure_snapshot(jsonb,uuid,uuid,jsonb,integer,integer) FROM PUBLIC;
