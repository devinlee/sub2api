-- 最终关闭前只核对原范围、售后责任和原赠送资格；不代替 Identity 的本人裁决，不产生资金效果。
CREATE FUNCTION meton_ledger.read_cash_closure_finalization(o jsonb,p_closure uuid,p_registration uuid,p_scope text,
    fact jsonb,p_eligibility uuid,until_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s meton_ledger.cash_closure_scopes;custodian text;page jsonb;item jsonb;cursor_value text;inventory jsonb;
    ready_count bigint:=0;pending_count bigint:=0;waiting_count bigint:=0;
BEGIN
    PERFORM meton_ledger.require_cash_closure_refund_actor(o,'read');
    -- 预查沿用只读事务，不能调用取得写锁的 require_cash_writer；最终交接仍由原写入口复验代次并加锁。
    IF pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR NOT EXISTS(
        SELECT FROM public.meton_managed_fence WHERE singleton AND enabled AND
            (environment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint)) THEN
        RAISE EXCEPTION 'current original final review unavailable' USING ERRCODE='55000'; END IF;
    SELECT * INTO s FROM meton_ledger.cash_closure_scopes WHERE closure_id=p_closure AND owner=o AND registration=p_registration
        AND receipt->>'scopeHash'=p_scope;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original closure range' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closing',until_at);
    IF p_eligibility IS NULL OR p_eligibility='00000000-0000-0000-0000-000000000000'::uuid OR
        EXISTS(SELECT FROM meton_ledger.registration_grants g WHERE g.source_marker=(o->>'source_marker')::uuid AND g.eligibility<>p_eligibility) OR
        EXISTS(SELECT FROM meton_ledger.cash_closure_snapshots snap,jsonb_array_elements(snap.items) snap_entry WHERE snap.snapshot_id=s.snapshot_id AND
            snap_entry->>'kind'='registration' AND snap_entry#>>'{value,eligibility}' IS NOT NULL AND (snap_entry#>>'{value,eligibility}')::uuid<>p_eligibility) THEN
        RAISE EXCEPTION 'original gift eligibility required' USING ERRCODE='42501'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_closure_refund_controls WHERE closure_id=p_closure AND stopped_at IS NOT NULL) OR
        EXISTS(SELECT FROM meton_ledger.cash_closure_final_facts WHERE closure_id=p_closure) THEN
        RAISE EXCEPTION 'original closure already decided' USING ERRCODE='42501'; END IF;
    SELECT responsible_ref INTO custodian FROM meton_ledger.cash_closure_aftercare_policies WHERE
        (deployment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    IF custodian IS NULL THEN RAISE EXCEPTION 'original aftercare responsibility unavailable' USING ERRCODE='55000'; END IF;
    LOOP
        page:=meton_ledger.read_cash_closure_targets(o,p_closure,p_registration,p_scope,cursor_value,100);
        FOR item IN SELECT value FROM jsonb_array_elements(page->'items') LOOP
            CASE item->>'state'
                WHEN 'ready' THEN ready_count:=ready_count+1;
                WHEN 'pending' THEN pending_count:=pending_count+1;
                WHEN 'waiting' THEN waiting_count:=waiting_count+1;
                ELSE RAISE EXCEPTION 'original closure target unavailable' USING ERRCODE='55000';
            END CASE;
            cursor_value:=item->>'cursor';
        END LOOP;
        IF until_at<=clock_timestamp() THEN RAISE EXCEPTION 'original final review expired' USING ERRCODE='55000'; END IF;
        EXIT WHEN (page->>'hasMore')::boolean IS FALSE;
    END LOOP;
    inventory:=meton_ledger.cash_closure_inventory(o);
    PERFORM meton_ledger.require_cash_closure_decision(o,s,fact,'closing',until_at);
    -- 可直接受理的原款应先走原退款；未知、尾差、过窗或占用继续由明确的售后责任承接，不强释 H／R。
    RETURN jsonb_build_object('format',1,'state',CASE WHEN ready_count=0 THEN 'finalization_ready' ELSE 'refunds_pending' END,
        'closure',p_closure,'registration',p_registration,'scopeHash',p_scope,'identity',fact,'giftEligibility',p_eligibility,
        'responsible',custodian,'rights','retained_original_sources','funds','not_declared_settled',
        'observedAt',clock_timestamp(),'validUntil',until_at,'inventory',inventory-'items',
        'ready',ready_count,'pending',pending_count,'waiting',waiting_count,'meaning','identity_final_decision_required');
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_cash_closure_finalization(jsonb,uuid,uuid,text,jsonb,uuid,timestamptz) FROM PUBLIC;

ALTER FUNCTION meton_ledger.checkout_cash_closure_refunds(text,jsonb,jsonb,uuid) RENAME TO checkout_cash_closure_refunds_v348;
CREATE FUNCTION meton_ledger.checkout_cash_closure_refunds(action text,q jsonb,orig jsonb,closure uuid) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner jsonb:=orig||jsonb_build_object('source_system',meton_ledger.notification_system_id());
BEGIN
    IF NOT q ? 'finalization' THEN RETURN meton_ledger.checkout_cash_closure_refunds_v348(action,q,orig,closure); END IF;
    IF action<>'closure_refunds' OR q->'finalization' IS DISTINCT FROM 'true'::jsonb OR
        q-ARRAY['version','origin','intent','registration','sourceSystem','scopeHash','decision','giftEligibility','finalization','validUntil']<>'{}'::jsonb OR
        q->>'sourceSystem' IS DISTINCT FROM owner->>'source_system' OR
        (q->>'registration'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND q->>'scopeHash'~'^[0-9a-f]{64}$' AND
            q->>'giftEligibility'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'read-only original final review required' USING ERRCODE='22023'; END IF;
    RETURN meton_ledger.read_cash_closure_finalization(owner,closure,(q->>'registration')::uuid,q->>'scopeHash',q->'decision',
        (q->>'giftEligibility')::uuid,(q->>'validUntil')::timestamptz)::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.checkout_cash_closure_refunds(text,jsonb,jsonb,uuid) FROM PUBLIC;
