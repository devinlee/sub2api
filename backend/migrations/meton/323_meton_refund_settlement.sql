-- 成功回执先独立提交。来源结清始终取原会员、原付款和原批次，现金渠道不参与这个事务。
CREATE TABLE meton_ledger.refund_settlement_roles(
    deployment text NOT NULL, source text NOT NULL, epoch bigint NOT NULL, key_ref uuid NOT NULL, resolver name NOT NULL,
    PRIMARY KEY(deployment,source,epoch,key_ref), UNIQUE(deployment,source,resolver)
);
CREATE TABLE meton_ledger.refund_cash_confirmations(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_gate_origins, envelope jsonb NOT NULL, cash jsonb NOT NULL,
    economic_hash bytea NOT NULL CHECK(octet_length(economic_hash)=32), recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE TABLE meton_ledger.refund_payment_disputes(
    refund uuid NOT NULL REFERENCES meton_ledger.refund_gate_origins, evidence bytea NOT NULL CHECK(octet_length(evidence)=32),
    reason text NOT NULL, positive_variants integer NOT NULL CHECK(positive_variants>=0), PRIMARY KEY(refund,evidence)
);
CREATE TABLE meton_ledger.refund_cash_postings(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.refund_cash_confirmations, marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker),
    payment uuid REFERENCES meton_ledger.cash_payments, cutoff uuid,
    credit uuid REFERENCES meton_ledger.lots, journal uuid UNIQUE REFERENCES meton_ledger.events DEFERRABLE INITIALLY DEFERRED,
    fen bigint NOT NULL CHECK(fen>0), units numeric(20,8) NOT NULL CHECK(units>=0),
    CHECK(num_nonnulls(payment,cutoff)=1 AND (units>0)=(credit IS NOT NULL) AND (credit IS NULL)=(journal IS NULL)),
    FOREIGN KEY(refund) REFERENCES meton_ledger.cash_refund_recoveries(refund_id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY(cutoff,marker) REFERENCES meton_ledger.legacy_balance_fences(cutoff,source_marker)
);
DO $protect$ DECLARE name text; BEGIN
    FOREACH name IN ARRAY ARRAY['refund_settlement_roles','refund_cash_confirmations','refund_payment_disputes','refund_cash_postings'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',name);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',name);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',name);
    END LOOP;
END $protect$;

CREATE FUNCTION meton_ledger.refund_payment_disputed(marker uuid,ord bigint,payment uuid,cut uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.refund_payment_disputes d JOIN meton_ledger.refund_gate_origins g USING(refund)
        JOIN meton_ledger.cash_refunds r ON r.refund_id=d.refund LEFT JOIN meton_ledger.cash_parts p ON p.part_id=r.part_id
        WHERE g.marker=$1 AND r.native_order=$2 AND (p.payment_id=$3 OR r.legacy_cutoff=$4))
$$;
CREATE FUNCTION meton_ledger.refund_observation_settled(s meton_ledger.cash_refund_observations) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.refund_cash_confirmations f JOIN meton_ledger.refund_cash_postings w USING(refund)
        JOIN meton_ledger.cash_refunds r ON r.refund_id=f.refund
        WHERE (w.marker,r.native_order,r.out_refund_no,r.phase)=(s.source_marker,s.native_order,s.facts->>'refundOrder','settled')
            AND s.facts->>'state'='SUCCESS' AND s.transaction_id=f.cash->>'transaction'
            AND s.facts @> f.cash AND NOT meton_ledger.refund_payment_disputed(w.marker,r.native_order,w.payment,w.cutoff))
$$;
CREATE FUNCTION meton_ledger.record_refund_dispute(ref uuid,digest bytea,why text,variants integer) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    INSERT INTO meton_ledger.refund_payment_disputes VALUES(ref,digest,why,variants) ON CONFLICT DO NOTHING;
    -- 已生效的结清或释放不可反转，争议独立留在同一笔实付上。
    UPDATE meton_ledger.cash_refunds SET phase='review',disposition_version=disposition_version+1
        WHERE refund_id=ref AND phase NOT IN ('review','settled','released');
    RETURN 'review';
END $$;

CREATE FUNCTION meton_ledger.post_confirmed_refund(m public.meton_managed_creations,r meton_ledger.cash_refunds,q meton_ledger.cash_refund_quotes,
    f meton_ledger.refund_cash_confirmations,payment uuid) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE credit uuid:=(q.snapshot->>'creditEvent')::uuid; units numeric:=coalesce(r.requested_units,0); reserved numeric;
    journal uuid; balance_before numeric; seq bigint; w meton_ledger.refund_cash_postings;
BEGIN
    IF r.phase='settled' THEN
        SELECT * INTO w FROM meton_ledger.refund_cash_postings WHERE refund=r.refund_id;
        IF (w.marker,w.payment,w.cutoff,w.credit,w.fen,w.units) IS DISTINCT FROM
            (m.source_marker,payment,r.legacy_cutoff,credit,r.requested_fen,units) OR NOT EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries h
            WHERE (h.refund_id,h.phase,h.terminal_version,h.confirmed_fen,h.confirmed_units,h.evidence)=
                (r.refund_id,'settled',r.disposition_version,r.requested_fen,units,f.economic_hash)) THEN RETURN 'recovery_review'; END IF;
        RETURN 'settled';
    END IF;
    IF r.phase<>'cash_confirmed' OR f.recorded_xid=pg_current_xact_id() THEN RETURN 'cash_confirmed'; END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries WHERE refund_id=r.refund_id) THEN RETURN 'recovery_review'; END IF;
    IF r.basis='purchased_source' THEN
        SELECT sum(x.requested_units) INTO reserved FROM meton_ledger.cash_refunds x JOIN meton_ledger.cash_refund_decisions d USING(refund_id)
            JOIN meton_ledger.cash_refund_quotes h USING(quote_id) WHERE d.source_marker=m.source_marker AND (h.snapshot->>'creditEvent')::uuid=credit
            AND x.phase NOT IN ('released','settled') AND x.basis='purchased_source';
        SELECT u.balance INTO STRICT balance_before FROM public.users u WHERE u.id=m.remote_user FOR UPDATE;
        IF balance_before IS DISTINCT FROM (SELECT sum(l.remaining) FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event
            WHERE e.source_marker=m.source_marker) THEN RETURN 'recovery_review'; END IF;
        UPDATE meton_ledger.lots SET refund_held=refund_held-units,remaining=remaining-units
            WHERE credit_event=credit AND refundable AND denomination='CNY' AND refund_held=reserved AND refund_held>=units AND remaining>=held+refund_held;
        IF NOT FOUND THEN RETURN 'recovery_review'; END IF;
        journal:=substr(encode(sha256(convert_to(jsonb_build_array('meton.cash.refund.settled.v1',r.refund_id)::text,'UTF8')),'hex'),1,32)::uuid;
    ELSIF payment IS NOT NULL THEN
        UPDATE meton_ledger.cash_payment_dispositions SET version=version+1 WHERE payment_id=payment AND state='restricted';
        IF NOT FOUND THEN RETURN 'recovery_review'; END IF;
    END IF;
    INSERT INTO meton_ledger.refund_cash_postings VALUES(r.refund_id,m.source_marker,payment,r.legacy_cutoff,credit,journal,r.requested_fen,units);
    IF journal IS NOT NULL THEN
        UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=m.source_marker RETURNING last_sequence INTO STRICT seq;
        INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
            VALUES(journal,m.environment,m.source,m.source_marker,journal,'purchase_refund',r.refund_id,seq,-units,balance_before,balance_before-units);
    END IF;
    UPDATE meton_ledger.cash_refunds SET phase='settled',disposition_version=disposition_version+1 WHERE refund_id=r.refund_id;
    INSERT INTO meton_ledger.cash_refund_recoveries VALUES(r.refund_id,r.disposition_version+1,'settled',r.requested_fen,units,f.economic_hash);
    RETURN 'settled';
END $$;

-- 独立收件库持有原付款锁并签出短期证明。首次写回只登记已退现金，下一事务才会使用原预占结清。
CREATE FUNCTION meton_ledger.resolve_original_refund(route jsonb,ref uuid,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE a meton_ledger.refund_gate_authorities; g meton_ledger.refund_gate_origins; d meton_ledger.cash_refund_decisions;
    q meton_ledger.cash_refund_quotes; r meton_ledger.cash_refunds; m public.meton_managed_creations; saved meton_ledger.refund_cash_confirmations;
    facts jsonb:=proof->'facts'; e jsonb:=facts->'envelope'; c jsonb:=facts->'cash'; s jsonb:=e->'scope'; domain text; owner jsonb;
    original jsonb; confirmed bytea; payment uuid; original_key uuid; current_scope jsonb; early_issue meton_ledger.refund_dispatch_bases;
BEGIN
    SELECT ga.* INTO a FROM meton_ledger.refund_gate_authorities ga JOIN meton_ledger.refund_settlement_roles w USING(deployment,source,epoch,key_ref)
        JOIN meton_ledger.refund_dispatch_policies p USING(deployment,source,epoch) JOIN public.meton_managed_fence n ON
            (n.environment,n.source,n.epoch)=(ga.deployment,ga.source,ga.epoch) AND n.singleton AND n.enabled
        WHERE (ga.deployment,ga.source,ga.epoch,w.resolver,ga.inbox_system,p.channel,p.cash_environment,p.merchant,p.app)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,session_user,route->>'inboxSystem',route->>'channel',route->>'cashEnvironment',
             route->>'merchant',route->>'app') AND NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_workers dw WHERE
            (dw.deployment,dw.source,dw.worker_role)=(ga.deployment,ga.source,session_user)) FOR SHARE OF ga,w,p,n;
    current_scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',meton_ledger.notification_system_id(),'inboxSystem',a.inbox_system);
    domain:=CASE proof->>'state' WHEN 'success_proved' THEN 'meton.refund.succeeded.v1' WHEN 'review' THEN 'meton.refund.disputed.v1' END;
    IF a.key_ref IS NULL OR domain IS NULL OR coalesce(octet_length(proof::text),0)>32768 OR facts->'format' IS DISTINCT FROM '1'::jsonb
        OR facts->'scope' IS DISTINCT FROM current_scope OR route->>'sourceSystem' IS DISTINCT FROM meton_ledger.notification_system_id()
        OR route->>'sourceSystem'=a.inbox_system OR current_setting('transaction_isolation')<>'read committed'
        OR (ref=(e#>>'{target,refund}')::uuid AND (facts->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE
        OR proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array(domain,facts)::text,'UTF8'),a.seal_key),'hex')
        THEN RAISE EXCEPTION 'verified current original refund resolution required' USING ERRCODE='42501'; END IF;
    SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.cash_refund_decisions WHERE refund_id=ref;
    IF g.refund IS NULL OR d.refund_id IS NULL THEN RETURN 'original_unavailable'; END IF;
    SELECT * INTO m FROM public.meton_managed_creations WHERE (source_marker,environment,source,epoch)=(g.marker,a.deployment,a.source,a.epoch) FOR SHARE;
    SELECT key_ref INTO original_key FROM meton_ledger.refund_dispatch_issuers WHERE refund=ref;
    IF m.source_marker IS NULL OR original_key IS NULL OR g.target IS DISTINCT FROM e->'target' OR
        (d.source_marker,d.intent_id,d.recorded_at) IS DISTINCT FROM (g.marker,(g.target->>'intent')::uuid,(e->>'acceptedAt')::timestamptz)
        OR NOT meton_ledger.refund_owner_succeeded(m,g.accepted_epoch) OR g.inbox_system<>a.inbox_system OR
        (s->>'deployment',s->>'source',(s->>'epoch')::bigint,(s->>'keyRef')::uuid,s->>'sourceSystem',s->>'inboxSystem',s->>'channel',s->>'cashEnvironment',s->>'merchant',s->>'app')
        IS DISTINCT FROM (a.deployment,a.source,g.accepted_epoch,original_key,g.source_system,g.inbox_system,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
        THEN RAISE EXCEPTION 'original resolution identity differs' USING ERRCODE='42501'; END IF;
    owner:=jsonb_build_object('environment',m.environment,'source',m.source,'epoch',m.epoch,'user',m.meton_user,'account',m.account,'creation',m.operation,
        'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker,'source_system',route->>'sourceSystem');
    PERFORM meton_ledger.require_refund_gate_writer(owner);
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(g.marker));
    SELECT * INTO STRICT q FROM meton_ledger.cash_refund_quotes WHERE (quote_id,source_marker)=(d.quote_id,g.marker);
    PERFORM meton_ledger.lock_refund_quote_target(owner,q);
    SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE (refund_id,intent_id)=(ref,d.intent_id) FOR UPDATE;
    SELECT * INTO early_issue FROM meton_ledger.refund_dispatch_bases WHERE refund=ref;
    IF early_issue.refund IS NOT NULL AND (early_issue.marker,early_issue.envelope) IS DISTINCT FROM (m.source_marker,e) THEN RETURN 'recovery_review'; END IF;
    IF r.part_id IS NOT NULL THEN
        SELECT payment_id INTO STRICT payment FROM meton_ledger.cash_parts WHERE (part_id,source_marker,native_order,basis)=(r.part_id,g.marker,r.native_order,r.basis);
    END IF;
    IF domain='meton.refund.disputed.v1' THEN
        IF (facts->>'reviewHash'~'^[a-f0-9]{64}$' AND (facts->>'confirmedCashVariants')::integer>=0) IS NOT TRUE THEN
            RAISE EXCEPTION 'invalid original dispute' USING ERRCODE='22023'; END IF;
        RETURN meton_ledger.record_refund_dispute(ref,decode(facts->>'reviewHash','hex'),'channel_conflict',(facts->>'confirmedCashVariants')::integer);
    END IF;
    confirmed:=sha256(convert_to(c::text,'UTF8'));
    IF encode(confirmed,'hex') IS DISTINCT FROM facts->>'economicHash' OR (c->>'order',c->>'transaction',c->>'refundOrder',c->>'total',(c->>'refundFen')::bigint)
       IS DISTINCT FROM (e#>>'{cash,order}',e#>>'{cash,transaction}',r.out_refund_no,e#>>'{cash,total}',r.requested_fen)
       OR (c->>'refundID'~'^[A-Za-z0-9_.:-]{1,64}$' AND (c->>'payerTotal')::bigint BETWEEN 0 AND (c->>'total')::bigint
           AND (c->>'payerRefund')::bigint BETWEEN 0 AND least((c->>'payerTotal')::bigint,r.requested_fen)
           AND (coalesce((e#>>'{cash,payerTotalUnrecorded}')::boolean,false) OR c->>'payerTotal'=e#>>'{cash,payerTotal}')) IS NOT TRUE
        THEN RAISE EXCEPTION 'refund economic result differs' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_ledger.refund_cash_confirmations(refund,envelope,cash,economic_hash) VALUES(ref,e,c,confirmed) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT saved FROM meton_ledger.refund_cash_confirmations WHERE refund=ref;
    IF (saved.envelope,saved.cash,saved.economic_hash) IS DISTINCT FROM (e,c,confirmed) OR r.phase='released' THEN
        RETURN meton_ledger.record_refund_dispute(ref,confirmed,'incompatible_source_terminal',1); END IF;
    IF meton_ledger.refund_payment_disputed(g.marker,r.native_order,payment,r.legacy_cutoff) THEN RETURN 'review'; END IF;
    IF r.phase NOT IN ('cash_confirmed','settled') THEN
        UPDATE meton_ledger.cash_refunds SET phase='cash_confirmed',disposition_version=disposition_version+1 WHERE refund_id=ref;
        RETURN 'cash_confirmed';
    END IF;
    IF r.legacy_cutoff IS NOT NULL AND m.epoch<>g.accepted_epoch THEN
        -- 恢复后原开户代次仍属旧截点。当前承接人、原生金额和两项渠道引用须与原冻结事实及独立归档同时相符。
        SELECT e->'cash'||jsonb_build_object('paidAt',e->'paidAt') INTO original FROM public.payment_orders n
            JOIN meton_ledger.legacy_cash_handoffs h ON (h.native_order,h.cutoff,h.source_marker)=(n.id,r.legacy_cutoff,m.source_marker)
            JOIN meton_ledger.legacy_cash_facts v ON (v.cutoff,v.kind,v.native_id)=(h.cutoff,'order',h.native_order)
            WHERE (n.id,n.user_id,n.out_trade_no,n.payment_trade_no)=(r.native_order,m.remote_user,e#>>'{cash,order}',e#>>'{cash,transaction}')
                AND (meton_ledger.legacy_hash(n.out_trade_no),meton_ledger.legacy_hash(n.payment_trade_no))=(v.proof->>'merchant_ref',v.proof->>'trade_ref')
                AND (v.proof->>'order_pay_amount')::numeric*100=(e#>>'{cash,total}')::numeric
                AND (n.paid_at=(e->>'paidAt')::timestamptz);
    ELSE original:=meton_ledger.original_refund_payment(owner,r,route); END IF;
    IF original IS NULL OR (original-'paidAt',original->'paidAt') IS DISTINCT FROM (e->'cash',e->'paidAt') THEN RETURN 'recovery_review'; END IF;
    RETURN meton_ledger.post_confirmed_refund(m,r,q,saved,payment);
END $$;

ALTER TABLE meton_ledger.events DROP CONSTRAINT events_kind_check,DROP CONSTRAINT events_signed_amount_check,
    ADD CONSTRAINT events_kind_check CHECK(kind IN ('grant','purchase','text_charge','text_revision','text_correction','gift_termination','legacy_refund_return','purchase_refund')),
    ADD CONSTRAINT events_signed_amount_check CHECK(amount BETWEEN -999999999999.99999999 AND 999999999999.99999999 AND
        CASE WHEN kind IN ('grant','purchase') THEN amount>=0 WHEN kind IN ('text_correction','legacy_refund_return') THEN amount>0
             WHEN kind IN ('text_charge','gift_termination','purchase_refund') THEN amount<0 ELSE amount<>0 END);

DO $guards$
DECLARE body text; point text;
BEGIN
    body:=pg_get_functiondef('meton_ledger.check_journal_backing()'::regprocedure);
    point:='    IF NEW.kind IN (''grant'',''purchase'') THEN';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'source journal backing changed'; END IF;
    EXECUTE replace(body,point,$back$    IF NEW.kind='purchase_refund' AND EXISTS(SELECT FROM meton_ledger.refund_cash_postings w
        JOIN meton_ledger.cash_refund_recoveries h ON h.refund_id=w.refund JOIN meton_ledger.events c ON c.event_id=w.credit
        WHERE (w.journal,w.marker,w.refund,-w.units)=(NEW.event_id,NEW.source_marker,NEW.origin_ref,NEW.amount) AND NEW.operation_id=w.journal
            AND c.kind='purchase' AND c.source_marker=w.marker AND (h.phase,h.confirmed_fen,h.confirmed_units)=('settled',w.fen,w.units)) THEN RETURN NULL; END IF;
$back$||point);
    body:=pg_get_functiondef('meton_ledger.statement_parts(uuid)'::regprocedure);
    point:='SELECT r.credit_event,-r.amount FROM original e JOIN meton_ledger.gift_retirements';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'source statement allocation changed'; END IF;
    EXECUTE replace(body,point,$parts$SELECT w.credit,-w.units FROM original e JOIN meton_ledger.refund_cash_postings w ON w.journal=e.event_id WHERE e.kind='purchase_refund'
        UNION ALL
        $parts$||point);
    body:=pg_get_functiondef('meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb)'::regprocedure);
    point:='proof_hash:=sha256(convert_to(jsonb_build_array(g.target,choice,f->>''ticket'')::text,''UTF8''));';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'refund release guard changed'; END IF;
    EXECUTE replace(body,point,$gate$IF EXISTS(SELECT FROM meton_ledger.refund_cash_confirmations WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_ledger.refund_payment_disputes WHERE refund=ref) THEN RETURN 'review'; END IF;
    $gate$||point);
    body:=pg_get_functiondef('meton_ledger.original_refund_snapshot(jsonb,bigint,uuid,uuid,text)'::regprocedure);
    point:='WHERE signal.native_order=order_id AND signal.transaction_id=pay.channel_transaction)';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'settled refund quotation changed'; END IF;
    body:=replace(body,point,'WHERE signal.native_order=order_id AND signal.transaction_id=pay.channel_transaction AND NOT meton_ledger.refund_observation_settled(signal))');
    point:='IF meton_ledger.has_text_shortfall(marker) THEN';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original payment restriction changed'; END IF;
    EXECUTE replace(body,point,'IF meton_ledger.refund_payment_disputed(marker,order_id,pay.payment_id,cutoff_ref) THEN RETURN jsonb_build_object(''state'',''review''); END IF; '||point);
    body:=pg_get_functiondef('meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)'::regprocedure);
    point:='IF NOT FOUND OR d.state NOT IN';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'purchase fulfilment guard changed'; END IF;
    EXECUTE replace(body,point,'IF NOT FOUND OR meton_ledger.refund_payment_disputed(marker,o.native_order,payment,NULL) OR EXISTS(SELECT FROM meton_ledger.refund_cash_postings w
        WHERE w.payment=payment AND w.credit IS NULL) OR d.state NOT IN');
END $guards$;
REVOKE ALL ON FUNCTION meton_ledger.resolve_original_refund(jsonb,uuid,jsonb),meton_ledger.refund_payment_disputed(uuid,bigint,uuid,uuid),
    meton_ledger.refund_observation_settled(meton_ledger.cash_refund_observations),meton_ledger.record_refund_dispute(uuid,bytea,text,integer),
    meton_ledger.post_confirmed_refund(public.meton_managed_creations,meton_ledger.cash_refunds,meton_ledger.cash_refund_quotes,meton_ledger.refund_cash_confirmations,uuid) FROM PUBLIC;

CREATE FUNCTION meton_ledger.refund_settlement_ready(route jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.refund_settlement_roles w JOIN meton_ledger.refund_gate_authorities a USING(deployment,source,epoch,key_ref)
        JOIN meton_ledger.refund_dispatch_policies p USING(deployment,source,epoch) JOIN public.meton_managed_fence n
            ON (n.environment,n.source,n.epoch)=(a.deployment,a.source,a.epoch) AND n.singleton AND n.enabled
        WHERE (a.deployment,a.source,a.epoch,a.inbox_system,w.resolver,p.channel,p.cash_environment,p.merchant,p.app)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'inboxSystem',session_user,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
            AND route->>'sourceSystem'=meton_ledger.notification_system_id() AND route->>'sourceSystem'<>a.inbox_system AND NOT pg_is_in_recovery()
            AND NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_workers dw WHERE (dw.deployment,dw.source,dw.worker_role)=(a.deployment,a.source,session_user)))
$$;
REVOKE ALL ON FUNCTION meton_ledger.refund_settlement_ready(jsonb) FROM PUBLIC;

-- 接管旧付款后由 Meton 受理的新退款也可能先收到通知。归属取冻结订单、原会员与渠道引用，不借用旧系统预扣退款的凭证。
CREATE FUNCTION meton_ledger.managed_historical_notice(dep text,src text,gen bigint,ch text,env text,mch text,app text,n jsonb) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('version',1,'managedHistoricalRefund',r.refund_id,'sourceMarker',m.source_marker,'user',m.meton_user,'account',m.account,
        'creation',m.operation,'order',p.out_trade_no,'channel',ch,'cashEnvironment',env,'merchant',mch,'app',$7,'currency','CNY',
        'priceFen',(f.proof->>'order_pay_amount')::numeric*100)
        FROM meton_ledger.cash_refunds r JOIN meton_ledger.refund_gate_origins g ON g.refund=r.refund_id
        JOIN public.meton_managed_creations m ON m.source_marker=g.marker
        JOIN meton_ledger.legacy_cash_handoffs h ON (h.cutoff,h.native_order,h.source_marker)=(r.legacy_cutoff,r.native_order,g.marker)
        JOIN meton_ledger.legacy_cash_facts f ON (f.cutoff,f.kind,f.native_id)=(h.cutoff,'order',h.native_order)
        JOIN meton_ledger.legacy_refund_routes cfg ON (cfg.deployment,cfg.source,cfg.provider_instance)=(m.environment,m.source,f.proof->>'provider_instance')
        JOIN public.payment_orders p ON (p.id,p.user_id)=(h.native_order,m.remote_user)
        WHERE n->>'kind'='refund' AND (r.out_refund_no,p.out_trade_no,p.payment_trade_no,n->>'merchant')=(n->>'refundOrder',n->>'order',n->>'transaction',mch)
            AND (m.environment,m.source,m.epoch,cfg.channel,cfg.cash_environment,cfg.merchant,cfg.app)=(dep,src,gen,ch,env,mch,$7)
            AND (meton_ledger.legacy_hash(p.out_trade_no),meton_ledger.legacy_hash(p.payment_trade_no))=(f.proof->>'merchant_ref',f.proof->>'trade_ref')
            AND meton_ledger.refund_owner_succeeded(m,g.accepted_epoch)
$$;
DO $historical$
DECLARE body text:=pg_get_functiondef('meton_ledger.legacy_refund_notice_origin(text,text,bigint,text,text,text,text,jsonb)'::regprocedure);
    point constant text:='IF n->>''kind'' IS DISTINCT FROM ''refund'' THEN RETURN NULL; END IF;';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original historical notification changed'; END IF;
    EXECUTE replace(body,point,point||$known$
    first_origin:=meton_ledger.managed_historical_notice(dep,src,gen,ch,env,mch,application,n);
    IF first_origin IS NOT NULL THEN RETURN first_origin; END IF;$known$);
END $historical$;
REVOKE ALL ON FUNCTION meton_ledger.managed_historical_notice(text,text,bigint,text,text,text,text,jsonb) FROM PUBLIC;
