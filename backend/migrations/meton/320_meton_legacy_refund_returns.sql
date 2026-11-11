-- 历史归还以原扣款为业务身份。接受证据不改变余额，资金效果只能随原来源的启用事务提交。
CREATE TABLE meton_ledger.legacy_refund_obligations(
    decision uuid PRIMARY KEY,marker uuid NOT NULL, native_order bigint NOT NULL,cutoff uuid NOT NULL,
    channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,refund_number text NOT NULL,
    facts jsonb NOT NULL, UNIQUE(marker,native_order), UNIQUE(channel,cash_environment,merchant,refund_number),
    FOREIGN KEY(cutoff,native_order) REFERENCES meton_ledger.legacy_cash_handoffs(cutoff,native_order)
);
CREATE TABLE meton_ledger.legacy_refund_checks(
    decision uuid PRIMARY KEY REFERENCES meton_ledger.legacy_refund_obligations, checked_xid xid8 NOT NULL, valid_until timestamptz NOT NULL
);
CREATE TABLE meton_ledger.legacy_refund_postings(
    decision uuid PRIMARY KEY REFERENCES meton_ledger.legacy_refund_obligations,review uuid NOT NULL REFERENCES meton_ledger.legacy_source_reviews,
    amount numeric(20,8) NOT NULL CHECK(amount>=0),
    journal uuid UNIQUE REFERENCES meton_ledger.events DEFERRABLE INITIALLY DEFERRED,
    CHECK((amount=0 AND journal IS NULL) OR (amount>0 AND journal=decision))
);
CREATE TABLE meton_ledger.legacy_refund_parts(
    decision uuid NOT NULL REFERENCES meton_ledger.legacy_refund_postings, credit uuid NOT NULL REFERENCES meton_ledger.legacy_opening_events(event_id),
    amount numeric(20,8) NOT NULL CHECK(amount>0), retired uuid UNIQUE REFERENCES meton_ledger.events DEFERRABLE INITIALLY DEFERRED,
    PRIMARY KEY(decision,credit)
);
DO $protect$
DECLARE n text;
BEGIN
    FOREACH n IN ARRAY ARRAY['legacy_refund_obligations','legacy_refund_postings','legacy_refund_parts'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',n);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
    END LOOP;
END $protect$;
REVOKE ALL ON meton_ledger.legacy_refund_obligations,meton_ledger.legacy_refund_checks,meton_ledger.legacy_refund_postings,meton_ledger.legacy_refund_parts FROM PUBLIC;

CREATE FUNCTION meton_ledger.accept_legacy_refund_return(o jsonb,original_cut uuid,p_order bigint,receipt jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE current_origin jsonb; a meton_ledger.refund_gate_authorities; scope jsonb; facts jsonb:=receipt->'facts'; target jsonb:=facts->'target';
    marker uuid:=(o->>'source_marker')::uuid; expires timestamptz:=(facts->>'validUntil')::timestamptz; decision_key uuid; existing meton_ledger.legacy_refund_obligations;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(o);
    PERFORM FROM public.users WHERE (id,meton_legacy_balance_fence)=((o->>'remote_user')::bigint,original_cut) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'original frozen owner unavailable' USING ERRCODE='42501'; END IF;
    current_origin:=meton_ledger.original_legacy_refund_debit(o,original_cut,p_order);
    SELECT * INTO STRICT a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint) FOR SHARE;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'sourceSystem',meton_ledger.notification_system_id(),'inboxSystem',a.inbox_system,'keyRef',a.key_ref);
    IF current_origin IS NULL OR current_origin->>'state' NOT IN ('held','returned') OR target IS DISTINCT FROM current_origin OR facts->'scope' IS DISTINCT FROM scope
        OR scope->>'sourceSystem'=a.inbox_system OR receipt->>'state' IS DISTINCT FROM 'proved' OR facts->>'format' IS DISTINCT FROM '1' OR
        expires IS NULL OR expires<=clock_timestamp() OR expires>clock_timestamp()+interval '30 seconds' OR
        receipt->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.legacy.refund.return.v1',facts)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'current original historical refund proof required' USING ERRCODE='42501'; END IF;
    decision_key:=substr(encode(sha256(convert_to(jsonb_build_array('meton.legacy.refund.operation.v1',marker,p_order,target->>'auditHash')::text,'UTF8')),'hex'),1,32)::uuid;
    INSERT INTO meton_ledger.legacy_refund_obligations VALUES(decision_key,marker,p_order,original_cut,target->>'channel',target->>'cashEnvironment',
        target->>'merchant',target->>'refundOrder',facts-'validUntil') ON CONFLICT DO NOTHING;
    SELECT * INTO existing FROM meton_ledger.legacy_refund_obligations WHERE decision=decision_key;
    IF existing.facts IS DISTINCT FROM facts-'validUntil' OR (existing.marker,existing.cutoff,existing.native_order) IS DISTINCT FROM (marker,original_cut,p_order) THEN
        RAISE EXCEPTION 'original debit already has a different disposition' USING ERRCODE='23505'; END IF;
    INSERT INTO meton_ledger.legacy_refund_checks VALUES(decision_key,pg_current_xact_id(),expires) ON CONFLICT(decision)
        DO UPDATE SET checked_xid=excluded.checked_xid,valid_until=excluded.valid_until;
    RETURN decision_key;
END $$;

-- 只允许确有原签名和旧扣款裁定的那笔冻结订单进入原 S2 审核。其余未决订单仍阻止启用。
CREATE FUNCTION meton_ledger.legacy_refund_resolved(cut uuid,ord bigint) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.legacy_refund_obligations d WHERE (d.cutoff,d.native_order)=(cut,ord))
$$;
CREATE FUNCTION meton_ledger.legacy_refund_open_component(rev uuid,component_number integer) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.legacy_source_components c JOIN meton_ledger.legacy_source_reviews r ON r.operation=c.review
        JOIN meton_ledger.legacy_refund_obligations d ON d.cutoff=r.cutoff
        CROSS JOIN LATERAL jsonb_array_elements(d.facts->'manifest'->'allocations') a
        WHERE (c.review,c.ordinal)=(rev,component_number) AND (a->>'kind',(a->>'nativeId')::bigint,(a->>'origin')::uuid)=(c.kind,c.native_id,c.origin))
$$;

ALTER TABLE meton_ledger.events DROP CONSTRAINT events_kind_check,DROP CONSTRAINT events_signed_amount_check,
    ADD CONSTRAINT events_kind_check CHECK(kind IN ('grant','purchase','text_charge','text_revision','text_correction','gift_termination','legacy_refund_return')),
    ADD CONSTRAINT events_signed_amount_check CHECK(amount BETWEEN -999999999999.99999999 AND 999999999999.99999999 AND
        CASE WHEN kind IN ('grant','purchase') THEN amount>=0 WHEN kind IN ('text_correction','legacy_refund_return') THEN amount>0
            WHEN kind IN ('text_charge','gift_termination') THEN amount<0 ELSE amount<>0 END);

-- 归还只加回审核所指的原批次。批次目前还剩多少和原历史归还的最大数量是不同的约束。
CREATE FUNCTION meton_ledger.post_legacy_refund_returns(cut uuid,rev uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE op meton_ledger.legacy_source_openings; d meton_ledger.legacy_refund_obligations; c meton_ledger.legacy_source_components;
    owner public.meton_managed_creations; part jsonb; lot_id uuid; amount numeric; recovered numeric; units numeric; current_balance numeric;
    seq bigint; retire_id uuid; old_part meton_ledger.legacy_refund_parts;
BEGIN
    SELECT * INTO STRICT op FROM meton_ledger.legacy_source_openings WHERE (cutoff,review)=(cut,rev);
    SELECT * INTO STRICT owner FROM public.meton_managed_creations WHERE source_marker=op.source_marker;
    SELECT balance INTO STRICT current_balance FROM public.users WHERE (id,meton_legacy_balance_fence)=(owner.remote_user,cut) FOR UPDATE;
    FOR d IN SELECT * FROM meton_ledger.legacy_refund_obligations WHERE (marker,cutoff)=(op.source_marker,cut) ORDER BY native_order LOOP
        IF EXISTS(SELECT FROM meton_ledger.legacy_refund_postings WHERE decision=d.decision) THEN CONTINUE; END IF;
        IF NOT EXISTS(SELECT FROM meton_ledger.legacy_refund_checks WHERE decision=d.decision AND checked_xid=pg_current_xact_id()
            AND valid_until>clock_timestamp()) OR (d.facts->'scope'->>'epoch')::bigint<>op.activation_epoch OR
            d.facts->'manifest'->>'unit' IS DISTINCT FROM (SELECT unit FROM meton_ledger.legacy_source_reviews WHERE operation=rev) THEN
            RAISE EXCEPTION 'fresh historical clearance and original unit required' USING ERRCODE='55000'; END IF;
        amount:=CASE WHEN d.facts->'target'->>'state'='held' THEN (d.facts->'target'->>'units')::numeric ELSE 0 END;
        INSERT INTO meton_ledger.legacy_refund_postings VALUES(d.decision,rev,amount,CASE WHEN amount>0 THEN d.decision END);
        IF amount=0 THEN CONTINUE; END IF;
        FOR part IN SELECT value FROM jsonb_array_elements(d.facts->'manifest'->'allocations') ORDER BY value->>'kind',value->>'origin' LOOP
            SELECT * INTO c FROM meton_ledger.legacy_source_components WHERE (review,kind,native_id,origin)=
                (rev,part->>'kind',(part->>'nativeId')::bigint,(part->>'origin')::uuid);
            SELECT event_id INTO lot_id FROM meton_ledger.legacy_opening_events WHERE (cutoff,review,ordinal)=(cut,rev,c.ordinal);
            IF lot_id IS NULL OR c.origin IS NULL THEN RAISE EXCEPTION 'missing reviewed original funding part' USING ERRCODE='23514'; END IF;
            units:=(part->>'units')::numeric;
            SELECT coalesce(sum(p.amount),0) INTO recovered FROM meton_ledger.legacy_refund_parts p WHERE credit=lot_id;
            IF units<=0 OR c.remaining+recovered+units>c.original_amount THEN RAISE EXCEPTION 'return exceeds original funding part' USING ERRCODE='23514'; END IF;
            retire_id:=NULL;
            IF c.kind='grant' AND EXISTS(SELECT FROM meton_ledger.legacy_qualification_facts q WHERE (q.environment,q.source,q.eligibility,q.state)=
                (owner.environment,owner.source,c.origin,'terminated')) THEN
                IF c.remaining<>0 THEN RAISE EXCEPTION 'original terminated gift has unresolved opening stock' USING ERRCODE='55000'; END IF;
                retire_id:=gen_random_uuid();
            END IF;
            INSERT INTO meton_ledger.legacy_refund_parts VALUES(d.decision,lot_id,units,retire_id);
            UPDATE meton_ledger.lots SET remaining=remaining+units WHERE credit_event=lot_id;
        END LOOP;
        IF (SELECT sum(amount_part.amount) FROM meton_ledger.legacy_refund_parts amount_part WHERE decision=d.decision) IS DISTINCT FROM amount OR
            current_balance+amount IS DISTINCT FROM (SELECT sum(l.remaining) FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event
                WHERE e.source_marker=op.source_marker) THEN RAISE EXCEPTION 'original debit parts do not match' USING ERRCODE='23514'; END IF;
        UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=op.source_marker RETURNING last_sequence INTO STRICT seq;
        INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
            VALUES(d.decision,owner.environment,owner.source,op.source_marker,d.decision,'legacy_refund_return',d.decision,seq,amount,current_balance,current_balance+amount);
        current_balance:=current_balance+amount;
        -- 注销终止的原赠送在同一事务结清本次迟到归还；不写注册赠送或给新账号可消费余额。
        FOR old_part IN SELECT * FROM meton_ledger.legacy_refund_parts WHERE decision=d.decision AND retired IS NOT NULL ORDER BY credit LOOP
            UPDATE meton_ledger.lots SET remaining=remaining-old_part.amount WHERE credit_event=old_part.credit;
            UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=op.source_marker RETURNING last_sequence INTO STRICT seq;
            INSERT INTO meton_ledger.events(event_id,environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
                VALUES(old_part.retired,owner.environment,owner.source,op.source_marker,old_part.retired,'gift_termination',old_part.retired,seq,-old_part.amount,current_balance,current_balance-old_part.amount);
            current_balance:=current_balance-old_part.amount;
        END LOOP;
    END LOOP;
END $$;

CREATE FUNCTION meton_ledger.find_legacy_refund_return(o jsonb,original_cut uuid,p_order bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE result jsonb;
BEGIN
    PERFORM meton_ledger.require_refund_owner(o);
    PERFORM meton_ledger.require_legacy_cash_cutoff(o,original_cut);
    SELECT jsonb_build_object('decision',d.decision,'state',CASE WHEN p.decision IS NULL THEN 'awaiting_opening'
            WHEN p.journal IS NULL THEN 'already_returned' ELSE 'posted' END,'journal',p.journal,'units',p.amount::text)
        INTO result FROM meton_ledger.legacy_refund_obligations d LEFT JOIN meton_ledger.legacy_refund_postings p USING(decision)
        WHERE (d.cutoff,d.native_order,d.marker)=(original_cut,p_order,(o->>'source_marker')::uuid);
    RETURN result;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.accept_legacy_refund_return(jsonb,uuid,bigint,jsonb),meton_ledger.find_legacy_refund_return(jsonb,uuid,bigint),
    meton_ledger.legacy_refund_resolved(uuid,bigint),meton_ledger.legacy_refund_open_component(uuid,integer),meton_ledger.post_legacy_refund_returns(uuid,uuid) FROM PUBLIC;
-- 复用 S2 已签收的开启、来源审查和资金触发器。只有登记了原扣款决定的订单和批次才走新增分支。
DO $extend$
DECLARE body text; a text; b text; c text;
BEGIN
    body:=pg_get_functiondef('meton_ledger.record_legacy_source_review(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text)'::regprocedure);
    a:='fact->>''state'' IS DISTINCT FROM ''COMPLETED''';
    b:='(fact->>''reported_refund'')::numeric IS DISTINCT FROM 0::numeric';
    c:='fact->>''refund_requested_at'' IS NOT NULL';
    IF cardinality(string_to_array(body,a))<>2 OR cardinality(string_to_array(body,b))<>2 OR cardinality(string_to_array(body,c))<>2 THEN
        RAISE EXCEPTION 'original purchase checks changed'; END IF;
    body:=replace(body,a,'('||a||' AND NOT meton_ledger.legacy_refund_resolved(p_cutoff,v_native_id))');
    body:=replace(body,b,'('||b||' AND NOT meton_ledger.legacy_refund_resolved(p_cutoff,v_native_id))');
    EXECUTE replace(body,c,'('||c||' AND NOT meton_ledger.legacy_refund_resolved(p_cutoff,v_native_id))');

    body:=pg_get_functiondef('meton_ledger.activate_legacy_source(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,text)'::regprocedure);
    a:='AND proof->>''state'' NOT IN (''COMPLETED'',''EXPIRED'',''CANCELLED'',''FAILED'')';
    b:='WHERE review=p_review AND remaining>0';
    c:='    RETURN p_operation;';
    IF cardinality(string_to_array(body,a))<>2 OR cardinality(string_to_array(body,b))<>3 OR cardinality(string_to_array(body,c))<>2 THEN
        RAISE EXCEPTION 'original source opening checks changed'; END IF;
    body:=replace(body,a,a||' AND NOT meton_ledger.legacy_refund_resolved(cutoff,native_id)');
    body:=replace(body,b,'WHERE review=p_review AND (remaining>0 OR meton_ledger.legacy_refund_open_component(review,ordinal))');
    EXECUTE replace(body,c,$finish$    IF EXISTS(SELECT FROM meton_ledger.legacy_refund_obligations WHERE cutoff=p_cutoff) THEN
        -- 原开启约束先核实冻结时的余额，再在同一事务内向原批次归还。外部看不到中间余额。
        SET CONSTRAINTS meton_ledger.complete_legacy_opening IMMEDIATE;
        SET CONSTRAINTS meton_ledger.complete_legacy_opening DEFERRED;
        PERFORM meton_ledger.post_legacy_refund_returns(p_cutoff,p_review);
    END IF;
$finish$||c);

    body:=pg_get_functiondef('meton_ledger.check_legacy_opening()'::regprocedure);
    a:='WHERE review=NEW.review AND remaining>0';
    IF cardinality(string_to_array(body,a))<>2 THEN RAISE EXCEPTION 'original source opening constraint changed'; END IF;
    EXECUTE replace(body,a,'WHERE review=NEW.review AND (remaining>0 OR meton_ledger.legacy_refund_open_component(review,ordinal))');

    body:=pg_get_functiondef('meton_ledger.check_journal_backing()'::regprocedure);
    a:='    IF NEW.kind IN (''grant'',''purchase'') THEN';
    IF cardinality(string_to_array(body,a))<>2 THEN RAISE EXCEPTION 'journal backing checks changed'; END IF;
    EXECUTE replace(body,a,$journal$    IF NEW.kind IN ('grant','purchase') AND NEW.amount=0 AND NOT EXISTS(
        SELECT FROM meton_ledger.legacy_opening_events x JOIN meton_ledger.legacy_source_components c USING(review,ordinal)
        WHERE x.event_id=NEW.event_id AND c.remaining=0 AND meton_ledger.legacy_refund_open_component(x.review,x.ordinal)) THEN
        RAISE EXCEPTION 'zero credit requires evidenced historical opening' USING ERRCODE='23514'; END IF;
    IF NEW.kind='legacy_refund_return' AND EXISTS(SELECT FROM meton_ledger.legacy_refund_postings p JOIN meton_ledger.legacy_refund_obligations d USING(decision)
        WHERE (p.journal,d.marker,p.amount,d.decision)=(NEW.event_id,NEW.source_marker,NEW.amount,NEW.origin_ref) AND NEW.operation_id=d.decision
            AND p.amount=(SELECT sum(x.amount) FROM meton_ledger.legacy_refund_parts x WHERE x.decision=d.decision)) THEN RETURN NULL; END IF;
    IF NEW.kind='gift_termination' AND EXISTS(SELECT FROM meton_ledger.legacy_refund_parts p JOIN meton_ledger.legacy_refund_obligations d USING(decision)
        WHERE (p.retired,d.marker,-p.amount)=(NEW.event_id,NEW.source_marker,NEW.amount) AND NEW.event_id=NEW.operation_id AND NEW.event_id=NEW.origin_ref) THEN RETURN NULL; END IF;
$journal$||a);

    body:=pg_get_functiondef('meton_ledger.statement_owner(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid)'::regprocedure);
    a:='JOIN public.meton_s1_funds_births b ON b.remote_user=c.remote_user AND b.operation=c.operation';
    b:='AND u.deleted_at IS NULL';
    IF cardinality(string_to_array(body,a))<>2 OR cardinality(string_to_array(body,b))<>2 THEN RAISE EXCEPTION 'statement owner checks changed'; END IF;
    body:=replace(body,a,'LEFT '||a);
    EXECUTE replace(body,b,'AND (b.remote_user IS NOT NULL OR meton_ledger.legacy_source_active(c.source_marker,p_epoch)) '||b);
    body:=pg_get_functiondef('meton_ledger.statement_parts(uuid)'::regprocedure);
    a:='SELECT r.credit_event,-r.amount FROM original e JOIN meton_ledger.gift_retirements';
    IF cardinality(string_to_array(body,a))<>2 THEN RAISE EXCEPTION 'statement allocation checks changed'; END IF;
    EXECUTE replace(body,a,$parts$SELECT p.credit,p.amount FROM original e JOIN meton_ledger.legacy_refund_parts p ON p.decision=e.event_id WHERE e.kind='legacy_refund_return'
        UNION ALL
        SELECT p.credit,-p.amount FROM original e JOIN meton_ledger.legacy_refund_parts p ON p.retired=e.event_id WHERE e.kind='gift_termination'
        UNION ALL
        $parts$||a);
    body:=pg_get_functiondef('meton_ledger.read_statement_page(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,date,date,bigint,uuid,bigint,integer)'::regprocedure);
    a:='''kind'',e.kind';
    IF cardinality(string_to_array(body,a))<>2 THEN RAISE EXCEPTION 'statement presentation changed'; END IF;
    EXECUTE replace(body,a,$kind$'kind',CASE WHEN e.amount=0 AND e.kind IN ('grant','purchase') AND EXISTS(SELECT FROM meton_ledger.legacy_opening_events h
        WHERE h.event_id=e.event_id) THEN 'legacy_opening' ELSE e.kind END$kind$);
END $extend$;
-- 运维一次可提交同一冻结账号的多笔原退款。原凭证晚于结果或应答丢失时，通过单笔查询读取已提交效果。
CREATE FUNCTION meton_ledger.open_legacy_refunds(o jsonb,original_cut uuid,activation uuid,rev uuid,evidence text,receipts jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE item jsonb; original_order bigint; a meton_ledger.legacy_source_openings;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(o);
    PERFORM meton_ledger.require_legacy_cash_cutoff(o,original_cut);
    IF jsonb_typeof(receipts) IS DISTINCT FROM 'array' OR jsonb_array_length(receipts) NOT BETWEEN 1 AND 100 OR octet_length(receipts::text)>16777216 OR
        (SELECT count(DISTINCT value->'facts'->'target'->>'order') FROM jsonb_array_elements(receipts))<>jsonb_array_length(receipts) THEN
        RAISE EXCEPTION 'expected independent original refund proofs' USING ERRCODE='22023'; END IF;
    PERFORM FROM public.users WHERE (id,meton_legacy_balance_fence)=((o->>'remote_user')::bigint,original_cut) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'original frozen owner unavailable' USING ERRCODE='42501'; END IF;
    SELECT * INTO a FROM meton_ledger.legacy_source_openings WHERE cutoff=original_cut;
    FOR item IN SELECT value FROM jsonb_array_elements(receipts) ORDER BY (value->'facts'->'target'->>'order')::bigint LOOP
        original_order:=(item->'facts'->'target'->>'order')::bigint;
        IF a.operation IS NOT NULL THEN
            IF (a.operation,a.review,a.evidence_ref,a.activation_epoch) IS DISTINCT FROM (activation,rev,evidence,(o->>'epoch')::bigint) OR NOT EXISTS(
                SELECT FROM meton_ledger.legacy_refund_obligations d JOIN meton_ledger.legacy_refund_postings p USING(decision)
                WHERE (d.marker,d.cutoff,d.native_order,d.facts)=((o->>'source_marker')::uuid,original_cut,original_order,(item->'facts')-'validUntil')) THEN
                RAISE EXCEPTION 'original refund activation conflict' USING ERRCODE='23505'; END IF;
        ELSE
            PERFORM meton_ledger.accept_legacy_refund_return(o,original_cut,original_order,item);
        END IF;
    END LOOP;
    IF jsonb_array_length(receipts)<>(SELECT count(*) FROM meton_ledger.legacy_refund_obligations WHERE cutoff=original_cut) THEN
        RAISE EXCEPTION 'original refund list incomplete' USING ERRCODE='22023'; END IF;
    IF a.operation IS NOT NULL THEN RETURN a.operation; END IF;
    RETURN meton_ledger.activate_legacy_source(o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'creation')::uuid,(o->>'user')::uuid,
        (o->>'account')::uuid,(o->>'dispatch')::uuid,(o->>'remote_user')::bigint,(o->>'source_marker')::uuid,original_cut,activation,rev,evidence);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.open_legacy_refunds(jsonb,uuid,uuid,uuid,text,jsonb) FROM PUBLIC;
