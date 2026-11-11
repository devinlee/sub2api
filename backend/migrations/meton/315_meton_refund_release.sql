-- 使用 PostgreSQL 自带的 pgcrypto。已安装在其他 schema 时绑定该扩展真实拥有的 HMAC 函数。
DO $crypto$
DECLARE ns name; routine oid;
BEGIN
    IF NOT EXISTS(SELECT FROM pg_extension WHERE extname='pgcrypto') THEN
        CREATE SCHEMA meton_refund_crypto;
        CREATE EXTENSION pgcrypto WITH SCHEMA meton_refund_crypto;
    END IF;
    SELECT n.nspname INTO STRICT ns FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='pgcrypto';
    routine:=to_regprocedure(format('%I.hmac(bytea,bytea,text)',ns));
    IF NOT EXISTS(SELECT FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE e.extname='pgcrypto'
        AND d.classid='pg_proc'::regclass AND d.objid=routine AND d.refclassid='pg_extension'::regclass AND d.deptype='e') THEN
        RAISE EXCEPTION 'refund receipt HMAC unavailable'; END IF;
    EXECUTE format('CREATE FUNCTION meton_ledger.refund_seal_mac(bytea,bytea) RETURNS bytea LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp AS %L',
        format('SELECT %I.hmac($1,$2,''sha256'')',ns));
END $crypto$;
REVOKE ALL ON FUNCTION meton_ledger.refund_seal_mac(bytea,bytea) FROM PUBLIC;

CREATE TABLE meton_ledger.refund_gate_authorities(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),inbox_system text NOT NULL,
    key_ref uuid NOT NULL,seal_key bytea NOT NULL CHECK(octet_length(seal_key)=32),PRIMARY KEY(deployment,source)
);
CREATE TABLE meton_ledger.refund_gate_origins(
    refund uuid PRIMARY KEY REFERENCES meton_ledger.cash_refunds,marker uuid NOT NULL,accepted_epoch bigint NOT NULL,
    source_system text NOT NULL,inbox_system text NOT NULL,target jsonb NOT NULL,CHECK(source_system<>inbox_system)
);
CREATE TRIGGER immutable_refund_gate_origin BEFORE UPDATE OR DELETE ON meton_ledger.refund_gate_origins
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_gate_origins ENABLE ALWAYS TRIGGER immutable_refund_gate_origin;
REVOKE ALL ON meton_ledger.refund_gate_authorities,meton_ledger.refund_gate_origins FROM PUBLIC;

-- 只在原退款受理事务中登记可用的截点外权威。老记录缺少这个事实时不能从「本库没有发送记录」推断未发。
CREATE FUNCTION meton_ledger.capture_refund_gate_origin() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_ledger.cash_refunds; q meton_ledger.cash_refund_quotes; a meton_ledger.refund_gate_authorities; target jsonb;
BEGIN
    SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE (refund_id,intent_id)=(NEW.refund_id,NEW.intent_id);
    SELECT * INTO STRICT q FROM meton_ledger.cash_refund_quotes WHERE (quote_id,source_marker)=(NEW.quote_id,NEW.source_marker);
    SELECT g.* INTO a FROM meton_ledger.refund_gate_authorities g JOIN public.meton_managed_creations m
        ON (m.environment,m.source,m.epoch)=(g.deployment,g.source,g.epoch)
        WHERE m.source_marker=NEW.source_marker AND g.epoch=q.generation FOR SHARE OF g;
    IF NOT FOUND THEN RETURN NEW; END IF;
    IF r.phase<>'held' OR r.disposition_version<>1 OR r.out_refund_no<>'R'||replace(r.refund_id::text,'-','')
        OR a.inbox_system=meton_ledger.notification_system_id() THEN RAISE EXCEPTION 'refund origin not ready' USING ERRCODE='55000'; END IF;
    target:=jsonb_build_object('refund',r.refund_id,'marker',NEW.source_marker,'intent',r.intent_id,'order',r.native_order::text,
        'part',r.part_id,'cutoff',r.legacy_cutoff,'basis',r.basis,'paramsHash',r.params_hash,'outRefundNo',r.out_refund_no,
        'fen',r.requested_fen::text,'units',r.requested_units::text);
    INSERT INTO meton_ledger.refund_gate_origins VALUES(r.refund_id,NEW.source_marker,q.generation,meton_ledger.notification_system_id(),a.inbox_system,target);
    RETURN NEW;
END $$;
CREATE TRIGGER capture_refund_gate_origin AFTER INSERT ON meton_ledger.cash_refund_decisions
    FOR EACH ROW WHEN (NEW.refund_id IS NOT NULL) EXECUTE FUNCTION meton_ledger.capture_refund_gate_origin();
ALTER TABLE meton_ledger.cash_refund_decisions ENABLE ALWAYS TRIGGER capture_refund_gate_origin;

CREATE FUNCTION meton_ledger.require_refund_gate_writer(o jsonb) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.require_cash_writer(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    PERFORM meton_ledger.require_refund_owner(o);
    IF current_setting('synchronous_commit') NOT IN ('on','remote_apply') OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
        OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_ledger','CREATE') OR
        has_column_privilege(session_user,'meton_ledger.refund_gate_authorities','seal_key','SELECT') OR
        EXISTS(SELECT FROM pg_class c WHERE (c.relnamespace='meton_ledger'::regnamespace OR c.oid IN ('public.users'::regclass,'public.payment_orders'::regclass,
            'public.meton_managed_fence'::regclass,'public.meton_managed_creations'::regclass)) AND c.relkind IN ('r','p') AND
            (has_table_privilege(session_user,c.oid,'DELETE,TRUNCATE,TRIGGER') OR has_any_column_privilege(session_user,c.oid,'INSERT,UPDATE'))) THEN
        RAISE EXCEPTION 'restricted current refund writer required' USING ERRCODE='42501'; END IF;
END $$;

-- 两种身份都从原账号、退款和当代配置取目标。拿到这份短期许可并没有获得外发资格。
CREATE FUNCTION meton_ledger.refund_gate_material(o jsonb,original uuid,ref uuid,want text,until_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.refund_gate_authorities; g meton_ledger.refund_gate_origins; scope jsonb;
BEGIN
    SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE (refund,marker,target->>'intent')=(ref,(o->>'source_marker')::uuid,original::text);
    SELECT * INTO a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=
        (o->>'environment',o->>'source',(o->>'epoch')::bigint) FOR SHARE;
    IF NOT FOUND OR g.refund IS NULL OR (g.accepted_epoch,g.source_system,g.inbox_system) IS DISTINCT FROM
        (a.epoch,meton_ledger.notification_system_id(),a.inbox_system) OR want IS NULL OR want NOT IN ('stopped','claimed')
        OR until_at IS NULL OR until_at<=clock_timestamp() OR until_at>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'original refund gate requires recovery' USING ERRCODE='55000'; END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'sourceSystem',g.source_system,
        'inboxSystem',g.inbox_system,'keyRef',a.key_ref,'validUntil',until_at);
    RETURN jsonb_build_object('scope',scope,'target',g.target,'originProof',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.origin.v1',want,scope,g.target)::text,'UTF8'),a.seal_key),'hex'));
END $$;

CREATE FUNCTION meton_ledger.prepare_refund_cancel(o jsonb,actor jsonb,original uuid,ref uuid,expected_version bigint,until_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE value jsonb;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(o);
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((o->>'source_marker')::uuid));
    PERFORM pg_advisory_xact_lock_shared(hashtextextended((o->>'source_marker')||':'||(actor->>'session'),0));
    value:=meton_ledger.read_original_refund_decision(o,actor,original,until_at);
    IF ref IS NULL OR expected_version IS NULL OR expected_version<1 OR (value->>'refund')::uuid IS DISTINCT FROM ref THEN
        RAISE EXCEPTION 'original member refund differs' USING ERRCODE='42501'; END IF;
    IF value->>'phase'='released' AND NOT EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries w WHERE
        (w.refund_id,w.terminal_version,w.phase)=(ref,(value->>'version')::bigint,'released')) THEN
        RAISE EXCEPTION 'refund release not reconciled' USING ERRCODE='55000'; END IF;
    IF value->>'phase'<>'held' THEN RETURN jsonb_build_object('current',value); END IF;
    IF (value->>'version')::bigint<>expected_version THEN RAISE EXCEPTION 'refund version differs' USING ERRCODE='23505'; END IF;
    RETURN meton_ledger.refund_gate_material(o,original,ref,'stopped',until_at);
END $$;

CREATE FUNCTION meton_ledger.prepare_refund_departure(o jsonb,original uuid,ref uuid,p_version bigint,until_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(o);
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_refunds r JOIN meton_ledger.cash_refund_decisions d USING(refund_id)
        WHERE (r.refund_id,r.intent_id,r.phase,r.disposition_version,d.source_marker)=
            (ref,original,'held',p_version,(o->>'source_marker')::uuid)) THEN RETURN NULL; END IF;
    RETURN meton_ledger.refund_gate_material(o,original,ref,'claimed',until_at);
END $$;

-- 只把截点外已证明的结论接回原退款。持久签名覆盖原号、归属、金额、处理身份和唯一票据。
CREATE FUNCTION meton_ledger.apply_refund_gate_receipt(o jsonb,original uuid,ref uuid,receipt jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.refund_gate_authorities; g meton_ledger.refund_gate_origins; q meton_ledger.cash_refund_quotes; r meton_ledger.cash_refunds;
    f jsonb:=receipt->'facts'; scope jsonb:=f->'scope'; choice text:=f->>'choice'; proof_hash bytea; credit uuid; total_held numeric;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(o);
    SELECT * INTO a FROM meton_ledger.refund_gate_authorities WHERE (deployment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint) FOR SHARE;
    SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE (refund,marker,target->>'intent')=(ref,(o->>'source_marker')::uuid,original::text);
    IF g.refund IS NULL OR a.key_ref IS NULL OR (g.accepted_epoch,g.source_system,g.inbox_system) IS DISTINCT FROM
        (a.epoch,meton_ledger.notification_system_id(),a.inbox_system) OR g.target IS DISTINCT FROM f->'target' OR f->'format' IS DISTINCT FROM '1'::jsonb OR
        (scope->>'deployment',scope->>'source',(scope->>'epoch')::bigint,scope->>'sourceSystem',scope->>'inboxSystem',(scope->>'keyRef')::uuid)
            IS DISTINCT FROM (a.deployment,a.source,a.epoch,g.source_system,g.inbox_system,a.key_ref) OR
        choice IS NULL OR choice NOT IN ('stopped','claimed') OR NOT coalesce((f->>'ticket')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid,false) OR
        receipt->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(f::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified original refund gate' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(g.marker));
    SELECT quote.* INTO STRICT q FROM meton_ledger.cash_refund_decisions d JOIN meton_ledger.cash_refund_quotes quote USING(quote_id)
        WHERE (d.refund_id,d.intent_id,d.source_marker)=(ref,original,g.marker);
    PERFORM meton_ledger.lock_refund_quote_target(o,q);
    SELECT * INTO STRICT r FROM meton_ledger.cash_refunds WHERE (refund_id,intent_id)=(ref,original) FOR UPDATE;
    proof_hash:=sha256(convert_to(jsonb_build_array(g.target,choice,f->>'ticket')::text,'UTF8'));
    IF r.phase='released' THEN
        IF EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries w WHERE (w.refund_id,w.terminal_version,w.phase,w.evidence)=
            (ref,r.disposition_version,'released',proof_hash)) THEN RETURN 'released'; END IF;
        RETURN 'review';
    END IF;
    IF r.phase<>'held' THEN RETURN r.phase; END IF;
    IF r.disposition_version<>1 OR EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries WHERE refund_id=ref)
        OR EXISTS(SELECT FROM meton_ledger.cash_refund_observations signal WHERE signal.native_order=r.native_order AND
            (signal.facts->>'refundOrder'=r.out_refund_no OR r.basis='unposted_cash' AND signal.transaction_id=
                (SELECT p.channel_transaction FROM meton_ledger.cash_payments p JOIN meton_ledger.cash_parts b USING(payment_id) WHERE b.part_id=r.part_id))) THEN
        RETURN 'review'; END IF;
    IF choice='claimed' THEN
        UPDATE meton_ledger.cash_refunds SET phase='possibly_sent',disposition_version=disposition_version+1 WHERE refund_id=ref;
        RETURN 'possibly_sent';
    END IF;
    IF r.basis='purchased_source' THEN
        credit:=(q.snapshot->>'creditEvent')::uuid;
        SELECT sum(x.requested_units) INTO total_held FROM meton_ledger.cash_refunds x JOIN meton_ledger.cash_refund_decisions d USING(refund_id)
            JOIN meton_ledger.cash_refund_quotes h USING(quote_id) WHERE d.source_marker=g.marker AND (h.snapshot->>'creditEvent')::uuid=credit
            AND x.phase NOT IN ('released','settled') AND x.basis='purchased_source';
        UPDATE meton_ledger.lots SET refund_held=refund_held-r.requested_units WHERE credit_event=credit AND refundable AND
            refund_held=total_held AND refund_held>=r.requested_units;
        IF NOT FOUND THEN RAISE EXCEPTION 'original purchase hold needs recovery' USING ERRCODE='55000'; END IF;
    ELSIF r.part_id IS NOT NULL THEN
        UPDATE meton_ledger.cash_payment_dispositions d SET version=version+1 FROM meton_ledger.cash_parts p
            WHERE p.part_id=r.part_id AND p.source_marker=g.marker AND d.payment_id=p.payment_id AND d.state='restricted';
        IF NOT FOUND THEN RAISE EXCEPTION 'original unposted cash needs recovery' USING ERRCODE='55000'; END IF;
    END IF;
    UPDATE meton_ledger.cash_refunds SET phase='released',disposition_version=disposition_version+1 WHERE refund_id=ref;
    INSERT INTO meton_ledger.cash_refund_recoveries VALUES(ref,r.disposition_version+1,'released',0,0,proof_hash);
    RETURN 'released';
END $$;
REVOKE ALL ON FUNCTION meton_ledger.capture_refund_gate_origin(),meton_ledger.require_refund_gate_writer(jsonb),
    meton_ledger.refund_gate_material(jsonb,uuid,uuid,text,timestamptz),meton_ledger.prepare_refund_cancel(jsonb,jsonb,uuid,uuid,bigint,timestamptz),
    meton_ledger.prepare_refund_departure(jsonb,uuid,uuid,bigint,timestamptz),meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb) FROM PUBLIC;
