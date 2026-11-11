-- 已接受的旧真实预扣本身就是原账号资金凭证；它不具有 S1 出生记录或现代 cash_refunds 行。
-- 沿原离线恢复入口承认这种凭证，完整旧 Key 退役、关闭栅栏和账号身份检查仍由原入口执行。
CREATE OR REPLACE FUNCTION meton_ledger.original_refund_cutoff_owner(m public.meton_managed_creations) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
        AND meton_ledger.legacy_balance_guard_ready() AND meton_ledger.legacy_cash_guards_ready() AND meton_ledger.legacy_activity_guards_ready()
        AND meton_ledger.legacy_opening_guards_ready()
        AND NOT EXISTS(SELECT FROM public.meton_s1_funds_births b WHERE b.remote_user=m.remote_user OR b.operation=m.operation)
        AND EXISTS(SELECT FROM meton_ledger.legacy_balance_fences b
            JOIN meton_ledger.legacy_cash_manifests c ON (c.cutoff,c.captured_xid)=(b.cutoff,b.cutoff_xid)
            JOIN meton_ledger.legacy_activity_manifests a ON (a.cutoff,a.captured_xid)=(b.cutoff,b.cutoff_xid)
            JOIN public.users u ON (u.id,u.meton_legacy_balance_fence)=(b.remote_user,b.cutoff)
            JOIN meton_ledger.legacy_cash_handoffs h ON (h.source_marker,h.cutoff)=(b.source_marker,b.cutoff)
            JOIN meton_ledger.legacy_cash_facts f ON (f.cutoff,f.kind,f.native_id)=(b.cutoff,'order',h.native_order)
            WHERE (b.remote_user,b.source_marker)=(m.remote_user,m.source_marker) AND meton_ledger.refund_owner_succeeded(m,b.cut_epoch)
                AND h.proof_hash=sha256(convert_to(f.proof::text,'UTF8')) AND (
                    EXISTS(SELECT FROM meton_ledger.cash_refunds r JOIN meton_ledger.refund_gate_origins g ON (g.refund,g.marker)=(r.refund_id,b.source_marker)
                        WHERE (r.legacy_cutoff,r.native_order)=(b.cutoff,h.native_order) AND g.target->>'cutoff'=b.cutoff::text
                            AND g.target->>'order'=h.native_order::text AND g.target->>'refund'=r.refund_id::text)
                    OR EXISTS(SELECT FROM meton_ledger.legacy_refund_obligations d
                        JOIN meton_ledger.legacy_cash_facts audit ON (audit.cutoff,audit.kind,audit.native_id)=
                            (b.cutoff,'order_audit',(d.facts#>>'{target,audit}')::bigint)
                        JOIN public.payment_audit_logs native_audit ON (native_audit.id,native_audit.order_id,native_audit.action)=
                            (audit.native_id,h.native_order::text,'REFUND_PENDING')
                        JOIN public.payment_orders native_order ON (native_order.id,native_order.user_id)=(h.native_order,m.remote_user)
                        WHERE (d.marker,d.cutoff,d.native_order)=(m.source_marker,b.cutoff,h.native_order)
                            AND (d.facts#>>'{target,marker}',d.facts#>>'{target,user}',d.facts#>>'{target,account}',d.facts#>>'{target,creation}')=
                                (m.source_marker::text,m.meton_user::text,m.account::text,m.operation::text)
                            AND (d.facts#>>'{scope,deployment}',d.facts#>>'{scope,source}',d.facts#>>'{scope,sourceSystem}')=
                                (m.environment,m.source,meton_ledger.notification_system_id())
                            AND meton_ledger.refund_owner_succeeded(m,(d.facts#>>'{scope,epoch}')::bigint)
                            AND d.facts#>>'{target,state}' IN ('held','returned')
                            AND (d.facts#>>'{target,cutoff}',d.facts#>>'{target,order}',audit.proof->>'order_id',audit.proof->>'action')=
                                (b.cutoff::text,h.native_order::text,h.native_order::text,'REFUND_PENDING')
                            AND d.facts#>>'{target,auditHash}'=audit.proof->>'detail_digest'
                            AND audit.proof->>'detail_digest'=meton_ledger.legacy_hash(native_audit.detail)
                            AND f.proof->>'trade_ref'=meton_ledger.legacy_hash(native_order.payment_trade_no)
                            AND f.proof->>'merchant_ref'=meton_ledger.legacy_hash(native_order.out_trade_no))))
$$;

-- 当前签章只决定这一次能否处理。业务原事实仍按首次批准的范围保存，不能把换代误当作第二笔归还。
CREATE FUNCTION meton_ledger.legacy_refund_immutable_facts(facts jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT facts-ARRAY['validUntil','originalScope']||jsonb_build_object('scope',coalesce(facts->'originalScope',facts->'scope'))
$$;
REVOKE ALL ON FUNCTION meton_ledger.legacy_refund_immutable_facts(jsonb) FROM PUBLIC;

DO $restore$
DECLARE definition text; anchor text;
BEGIN
    definition:=pg_get_functiondef('meton_ledger.accept_legacy_refund_return(jsonb,uuid,bigint,jsonb)'::regprocedure);
    anchor:='marker uuid:=(o->>''source_marker'')::uuid;';
    IF cardinality(string_to_array(definition,anchor))<>2 THEN RAISE EXCEPTION 'original refund owner changed'; END IF;
    definition:=replace(definition,anchor,'owner public.meton_managed_creations; original_scope jsonb; '||anchor);
    anchor:='    decision_key:=substr(';
    IF cardinality(string_to_array(definition,anchor))<>2 THEN RAISE EXCEPTION 'original refund identity changed'; END IF;
    definition:=replace(definition,anchor,$proof$
    SELECT * INTO STRICT owner FROM public.meton_managed_creations WHERE source_marker=marker;
    original_scope:=coalesce(facts->'originalScope',scope);
    IF jsonb_typeof(original_scope) IS DISTINCT FROM 'object' OR original_scope-ARRAY['epoch','keyRef'] IS DISTINCT FROM scope-ARRAY['epoch','keyRef']
        OR (original_scope->>'epoch')::bigint NOT BETWEEN 1 AND owner.epoch OR (original_scope->>'keyRef')::uuid IS NULL
        OR NOT meton_ledger.refund_owner_succeeded(owner,(original_scope->>'epoch')::bigint) THEN
        RAISE EXCEPTION 'original historical refund succession required' USING ERRCODE='42501'; END IF;
$proof$||anchor);
    anchor:='facts-''validUntil''';
    IF cardinality(string_to_array(definition,anchor))<>3 THEN RAISE EXCEPTION 'immutable original disposition changed'; END IF;
    EXECUTE replace(definition,anchor,'meton_ledger.legacy_refund_immutable_facts(facts)');

    definition:=pg_get_functiondef('meton_ledger.post_legacy_refund_returns(uuid,uuid)'::regprocedure);
    anchor:='(d.facts->''scope''->>''epoch'')::bigint<>op.activation_epoch';
    IF cardinality(string_to_array(definition,anchor))<>2 THEN RAISE EXCEPTION 'original posting generation changed'; END IF;
    EXECUTE replace(definition,anchor,'(NOT meton_ledger.refund_owner_succeeded(owner,(d.facts->''scope''->>''epoch'')::bigint) OR owner.epoch<>op.activation_epoch)');

    -- 恢复后已存在的期初仍是同一笔期初。原开放栅栏和当前账号必须匹配，旧代次不能借这条连续链使用当前权限。
    definition:=pg_get_functiondef('meton_ledger.legacy_source_active(uuid,bigint)'::regprocedure);
    anchor:='a.activation_epoch=p_epoch';
    IF cardinality(string_to_array(definition,anchor))<>2 THEN RAISE EXCEPTION 'legacy active scope changed'; END IF;
    EXECUTE replace(definition,anchor,'meton_ledger.refund_owner_succeeded(m,a.activation_epoch)');
END $restore$;

-- 已有归还重试也先验当前签章；只取回原结果，不因恢复改写不可变的期初或原分配。
CREATE OR REPLACE FUNCTION meton_ledger.open_legacy_refunds(o jsonb,original_cut uuid,activation uuid,rev uuid,evidence text,receipts jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE item jsonb; original_order bigint; a meton_ledger.legacy_source_openings; owner public.meton_managed_creations;
BEGIN
    PERFORM meton_ledger.require_refund_gate_writer(o);
    PERFORM meton_ledger.require_legacy_cash_cutoff(o,original_cut);
    IF jsonb_typeof(receipts) IS DISTINCT FROM 'array' OR jsonb_array_length(receipts) NOT BETWEEN 1 AND 100 OR octet_length(receipts::text)>16777216 OR
        (SELECT count(DISTINCT value->'facts'->'target'->>'order') FROM jsonb_array_elements(receipts))<>jsonb_array_length(receipts) THEN
        RAISE EXCEPTION 'expected independent original refund proofs' USING ERRCODE='22023'; END IF;
    PERFORM FROM public.users WHERE (id,meton_legacy_balance_fence)=((o->>'remote_user')::bigint,original_cut) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'original frozen owner unavailable' USING ERRCODE='42501'; END IF;
    SELECT * INTO STRICT owner FROM public.meton_managed_creations WHERE source_marker=(o->>'source_marker')::uuid;
    SELECT * INTO a FROM meton_ledger.legacy_source_openings WHERE cutoff=original_cut;
    FOR item IN SELECT value FROM jsonb_array_elements(receipts) ORDER BY (value->'facts'->'target'->>'order')::bigint LOOP
        original_order:=(item->'facts'->'target'->>'order')::bigint;
        PERFORM meton_ledger.accept_legacy_refund_return(o,original_cut,original_order,item);
        IF a.operation IS NOT NULL AND (
            (a.operation,a.review,a.evidence_ref) IS DISTINCT FROM (activation,rev,evidence) OR
            NOT meton_ledger.refund_owner_succeeded(owner,a.activation_epoch) OR NOT EXISTS(
                SELECT FROM meton_ledger.legacy_refund_obligations d JOIN meton_ledger.legacy_refund_postings p USING(decision)
                WHERE (d.marker,d.cutoff,d.native_order,d.facts)=((o->>'source_marker')::uuid,original_cut,original_order,meton_ledger.legacy_refund_immutable_facts(item->'facts')))) THEN
            RAISE EXCEPTION 'original refund activation conflict' USING ERRCODE='23505'; END IF;
    END LOOP;
    IF jsonb_array_length(receipts)<>(SELECT count(*) FROM meton_ledger.legacy_refund_obligations WHERE cutoff=original_cut) THEN
        RAISE EXCEPTION 'original refund list incomplete' USING ERRCODE='22023'; END IF;
    IF a.operation IS NOT NULL THEN RETURN a.operation; END IF;
    RETURN meton_ledger.activate_legacy_source(o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'creation')::uuid,(o->>'user')::uuid,
        (o->>'account')::uuid,(o->>'dispatch')::uuid,(o->>'remote_user')::bigint,(o->>'source_marker')::uuid,original_cut,activation,rev,evidence);
END $$;
