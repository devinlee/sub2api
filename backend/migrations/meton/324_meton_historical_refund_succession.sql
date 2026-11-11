-- S1 新账号有开户事实；早于 S1 的账号可用 S2 原冻结和已接管的付款证明其归属。
-- 两条路径共享离线冻结、原用户复验和全部旧 Key 关闭条件。接续不创建开户、余额、Key 或新的发送权。
CREATE FUNCTION meton_ledger.original_refund_cutoff_owner(m public.meton_managed_creations) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
        AND meton_ledger.legacy_balance_guard_ready() AND meton_ledger.legacy_cash_guards_ready() AND meton_ledger.legacy_activity_guards_ready()
        AND NOT EXISTS(SELECT FROM public.meton_s1_funds_births b WHERE b.remote_user=m.remote_user OR b.operation=m.operation)
        AND EXISTS(SELECT FROM meton_ledger.legacy_balance_fences b
            JOIN meton_ledger.legacy_cash_manifests c ON (c.cutoff,c.captured_xid)=(b.cutoff,b.cutoff_xid)
            JOIN meton_ledger.legacy_activity_manifests a ON (a.cutoff,a.captured_xid)=(b.cutoff,b.cutoff_xid)
            JOIN public.users u ON (u.id,u.meton_legacy_balance_fence)=(b.remote_user,b.cutoff)
            JOIN meton_ledger.legacy_cash_handoffs h ON (h.source_marker,h.cutoff)=(b.source_marker,b.cutoff)
            JOIN meton_ledger.legacy_cash_facts f ON (f.cutoff,f.kind,f.native_id)=(b.cutoff,'order',h.native_order)
            JOIN meton_ledger.cash_refunds r ON (r.legacy_cutoff,r.native_order)=(b.cutoff,h.native_order)
            JOIN meton_ledger.refund_gate_origins g ON (g.refund,g.marker)=(r.refund_id,b.source_marker)
            WHERE (b.remote_user,b.source_marker)=(m.remote_user,m.source_marker) AND meton_ledger.refund_owner_succeeded(m,b.cut_epoch)
                AND h.proof_hash=sha256(convert_to(f.proof::text,'UTF8')) AND g.target->>'cutoff'=b.cutoff::text
                AND g.target->>'order'=h.native_order::text AND g.target->>'refund'=r.refund_id::text)
$$;
REVOKE ALL ON FUNCTION meton_ledger.original_refund_cutoff_owner(public.meton_managed_creations) FROM PUBLIC;
DO $original$
DECLARE signature constant text:='public.meton_recover_original(text,uuid,uuid,bigint,bigint,text,uuid,uuid,uuid,bigint,uuid,text)';
    def text:=pg_get_functiondef(signature::regprocedure);
    join_birth constant text:='FROM public.users u JOIN public.meton_s1_funds_births b ON b.remote_user=u.id AND b.operation=p_creation';
    check_user constant text:='WHERE u.id=p_remote AND u.status=''active''';
    check_unknown constant text:='OR EXISTS (SELECT FROM public.api_keys k WHERE k.user_id=p_remote AND NOT EXISTS';
    check_retired constant text:='JOIN public.meton_managed_session_closures c ON c.source_marker=x.source_marker AND c.session_id=x.session_id';
BEGIN
    IF cardinality(string_to_array(def,join_birth))<>2 OR cardinality(string_to_array(def,check_user))<>2 OR
        cardinality(string_to_array(def,check_unknown))<>2 OR cardinality(string_to_array(def,check_retired))<>2 THEN
        RAISE EXCEPTION 'original offline recovery or old key checks changed'; END IF;
    def:=replace(def,join_birth,'FROM public.users u LEFT JOIN public.meton_s1_funds_births b ON b.remote_user=u.id AND b.operation=p_creation');
    EXECUTE replace(def,check_user,'WHERE (b.remote_user IS NOT NULL OR meton_ledger.original_refund_cutoff_owner(a)) AND u.id=p_remote AND u.status=''active''');
END $original$;
