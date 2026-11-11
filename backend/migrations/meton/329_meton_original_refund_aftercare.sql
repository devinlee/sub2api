-- 售后沿同一原退款登记。申请不是付款人核验、替代付款批准或现金凭证，不创建另一份本金和冻结。
CREATE TABLE meton_ledger.refund_aftercare_cases(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_gate_origins,
    marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker),
    intent uuid NOT NULL, envelope jsonb NOT NULL,
    reason text NOT NULL CHECK(reason IN ('window_elapsed','payer_account_unavailable')),
    opened_epoch bigint NOT NULL CHECK(opened_epoch>0), opened_by name NOT NULL,
    opened_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_aftercare_cases
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_aftercare_cases ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_aftercare_cases FROM PUBLIC;

/** 原退款和原付款共同决定售后对象。重建后只接受既有承接链，外部申请不能选择账号或改变金额。 */
CREATE FUNCTION meton_ledger.original_refund_aftercare_context(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    g meton_ledger.refund_gate_origins;d meton_ledger.cash_refund_decisions;q meton_ledger.cash_refund_quotes;
    r meton_ledger.cash_refunds;m public.meton_managed_creations;b meton_ledger.refund_dispatch_bases;
    issuer meton_ledger.refund_dispatch_issuers;p meton_ledger.refund_dispatch_policies;
    owner jsonb;wire jsonb;e jsonb;s jsonb;
BEGIN
    SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.cash_refund_decisions WHERE refund_id=ref;
    SELECT * INTO issuer FROM meton_ledger.refund_dispatch_issuers WHERE refund=ref;
    SELECT * INTO m FROM public.meton_managed_creations WHERE (source_marker,environment,source,epoch)=
        (g.marker,a.deployment,a.source,a.epoch) FOR SHARE;
    IF g.refund IS NULL OR d.refund_id IS NULL OR issuer.refund IS NULL OR m.source_marker IS NULL THEN RETURN NULL; END IF;
    IF NOT meton_ledger.refund_owner_succeeded(m,g.accepted_epoch) OR
        (g.marker,g.target->>'intent',g.inbox_system,g.source_system,g.accepted_epoch) IS DISTINCT FROM
        (d.source_marker,d.intent_id::text,a.inbox_system,route->>'sourceSystem',issuer.epoch) OR
        (issuer.source_system,issuer.inbox_system) IS DISTINCT FROM (g.source_system,g.inbox_system) THEN
        RAISE EXCEPTION 'aftercare original owner requires recovery' USING ERRCODE='42501'; END IF;
    owner:=jsonb_build_object('environment',m.environment,'source',m.source,'epoch',m.epoch,'user',m.meton_user,'account',m.account,
        'creation',m.operation,'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker,'source_system',route->>'sourceSystem');
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(g.marker));
    SELECT * INTO STRICT q FROM meton_ledger.cash_refund_quotes WHERE (quote_id,source_marker)=(d.quote_id,g.marker);
    PERFORM meton_ledger.lock_refund_quote_target(owner,q);
    SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE (refund_id,intent_id)=(ref,d.intent_id) FOR UPDATE;
    SELECT * INTO b FROM meton_ledger.refund_dispatch_bases WHERE refund=ref;
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',g.accepted_epoch,'keyRef',issuer.key_ref,
        'sourceSystem',g.source_system,'inboxSystem',g.inbox_system,'channel',route->>'channel',
        'cashEnvironment',route->>'cashEnvironment','merchant',route->>'merchant','app',route->>'app');
    IF b.refund IS NOT NULL THEN
        e:=b.envelope;
        IF (b.marker,e->'scope',e->'target',(e->>'acceptedAt')::timestamptz) IS DISTINCT FROM (g.marker,s,g.target,d.recorded_at) THEN
            RAISE EXCEPTION 'aftercare original dispatch differs' USING ERRCODE='42501'; END IF;
    ELSE
        -- 原查询窗口已过时普通派发器不会创建出站包。这里仅冻结售后材料，不签发发送票据。
        SELECT * INTO p FROM meton_ledger.refund_dispatch_policies WHERE (deployment,source,epoch,channel,cash_environment,merchant,app)=
            (a.deployment,a.source,g.accepted_epoch,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app');
        wire:=meton_ledger.original_refund_payment(owner,r,route);
        IF p.deployment IS NULL OR wire IS NULL THEN RETURN NULL; END IF;
        e:=jsonb_build_object('format',1,'scope',s,'target',g.target,'cash',wire-'paidAt','paidAt',wire->'paidAt','acceptedAt',d.recorded_at,
            'sendUntil',least((wire->>'paidAt')::timestamptz+interval '8760 hours',d.recorded_at+make_interval(secs=>p.send_seconds)),
            'queryUntil',d.recorded_at+make_interval(secs=>p.query_seconds));
    END IF;
    IF (e#>>'{cash,refundOrder}',e#>>'{cash,refundFen}',g.target->>'refund',g.target->>'fen') IS DISTINCT FROM
        (r.out_refund_no,r.requested_fen::text,r.refund_id::text,r.requested_fen::text) THEN
        RAISE EXCEPTION 'aftercare original share differs' USING ERRCODE='42501'; END IF;
    RETURN jsonb_build_object('marker',g.marker,'intent',r.intent_id,'envelope',e,'phase',r.phase,
        'basis',r.basis,'fen',r.requested_fen,'units',r.requested_units,'version',r.disposition_version,'epoch',a.epoch);
END $$;

/** 状态按原退款实时读取；原渠道晚到成功或合法取消不被一张售后申请覆盖。 */
CREATE FUNCTION meton_ledger.refund_aftercare_view(ref uuid,context jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c meton_ledger.refund_aftercare_cases;phase text:=context->>'phase';
BEGIN
    IF context IS NULL THEN RETURN jsonb_build_object('state','original_unavailable'); END IF;
    SELECT * INTO c FROM meton_ledger.refund_aftercare_cases WHERE refund=ref;
    IF c.refund IS NOT NULL AND (c.marker,c.intent,c.envelope) IS DISTINCT FROM
        ((context->>'marker')::uuid,(context->>'intent')::uuid,context->'envelope') THEN
        RETURN jsonb_build_object('state','recovery_review'); END IF;
    RETURN jsonb_build_object('state',CASE WHEN phase='settled' THEN 'original_settled' WHEN phase='released' THEN 'original_released'
        WHEN phase='cash_confirmed' THEN 'original_cash_confirmed' WHEN c.refund IS NULL THEN 'not_opened' ELSE 'pending_verification' END,
        'refund',ref,'intent',context->'intent','originalPhase',phase,'basis',context->'basis','fen',context->'fen','units',context->'units',
        'version',context->'version','reason',c.reason,'openedAt',c.opened_at,'payerVerified',false,'alternativeAuthorized',false,'alternativePaid',false);
END $$;

CREATE FUNCTION meton_ledger.read_original_refund_aftercare(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.refund_aftercare_view(ref,meton_ledger.original_refund_aftercare_context(route,ref))
$$;

/** 同一原意图只开一项待核验售后。窗口由冻结原单判断，付款账户不可用仍是待证明的报告。 */
CREATE FUNCTION meton_ledger.open_original_refund_aftercare(route jsonb,ref uuid,reported_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);c meton_ledger.refund_aftercare_cases;result jsonb;
BEGIN
    IF reported_reason IS NULL OR reported_reason NOT IN ('window_elapsed','payer_account_unavailable') THEN
        RAISE EXCEPTION 'invalid aftercare reason' USING ERRCODE='22023'; END IF;
    result:=meton_ledger.refund_aftercare_view(ref,context);
    IF result->>'state' IN ('original_unavailable','recovery_review','original_settled','original_released','original_cash_confirmed') THEN RETURN result; END IF;
    SELECT * INTO c FROM meton_ledger.refund_aftercare_cases WHERE refund=ref;
    IF c.refund IS NOT NULL THEN RETURN result; END IF;
    IF reported_reason='window_elapsed' AND ((context#>>'{envelope,sendUntil}')::timestamptz<=clock_timestamp()) IS NOT TRUE THEN
        RETURN result||jsonb_build_object('state','original_window_available'); END IF;
    INSERT INTO meton_ledger.refund_aftercare_cases(refund,marker,intent,envelope,reason,opened_epoch,opened_by)
        VALUES(ref,(context->>'marker')::uuid,(context->>'intent')::uuid,context->'envelope',reported_reason,(context->>'epoch')::bigint,session_user);
    -- 不修改原 phase、R 或调度租约。申请未获准前仍允许原号查询、正常原路结清或有证明的会员取消。
    RETURN meton_ledger.refund_aftercare_view(ref,context);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.original_refund_aftercare_context(jsonb,uuid),meton_ledger.refund_aftercare_view(uuid,jsonb),
    meton_ledger.read_original_refund_aftercare(jsonb,uuid),meton_ledger.open_original_refund_aftercare(jsonb,uuid,text) FROM PUBLIC;
