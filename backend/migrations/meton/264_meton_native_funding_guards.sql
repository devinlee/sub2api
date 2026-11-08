-- 旧资金角色即使误获切换复制模式的权限，也必须经过原有业务触发器。
-- 复制或导入不能补造本应只由主库受控建号事务产生的资金出生证明。
CREATE TRIGGER meton_s2_primary_birth BEFORE INSERT OR UPDATE OR DELETE ON public.meton_s1_funds_births
    FOR EACH ROW WHEN (current_setting('session_replication_role') <> 'origin')
    EXECUTE FUNCTION meton_ledger.keep_event();

ALTER TABLE public.users ENABLE ALWAYS TRIGGER meton_s1_no_native_balance;
ALTER TABLE public.users ENABLE ALWAYS TRIGGER meton_s1_new_birth;
ALTER TABLE public.meton_managed_creations ENABLE ALWAYS TRIGGER meton_s1_bind_birth;
ALTER TABLE public.meton_s1_funds_births ENABLE ALWAYS TRIGGER meton_s1_keep_birth;
ALTER TABLE public.meton_s1_funds_births ENABLE ALWAYS TRIGGER meton_s2_primary_birth;
ALTER TABLE public.payment_orders ENABLE ALWAYS TRIGGER meton_s1_no_order;
ALTER TABLE public.redeem_codes ENABLE ALWAYS TRIGGER meton_s1_no_redeem;
ALTER TABLE public.promo_code_usages ENABLE ALWAYS TRIGGER meton_s1_no_promo;
ALTER TABLE public.user_subscriptions ENABLE ALWAYS TRIGGER meton_s1_no_subscription;
ALTER TABLE public.usage_logs ENABLE ALWAYS TRIGGER meton_s1_no_usage;
ALTER TABLE public.usage_billing_dedup ENABLE ALWAYS TRIGGER meton_s1_no_dedup;
ALTER TABLE public.usage_billing_dedup_archive ENABLE ALWAYS TRIGGER meton_s1_no_archived_dedup;
ALTER TABLE public.user_affiliates ENABLE ALWAYS TRIGGER meton_s1_no_affiliate;
ALTER TABLE public.user_affiliate_ledger ENABLE ALWAYS TRIGGER meton_s1_no_affiliate_ledger;
ALTER TABLE public.user_allowed_groups ENABLE ALWAYS TRIGGER meton_s1_no_group;
ALTER TABLE public.api_keys ENABLE ALWAYS TRIGGER meton_s1_only_managed_key;
ALTER TABLE public.user_provider_default_grants ENABLE ALWAYS TRIGGER meton_s2_no_first_bind;

-- 这些表已被本事务的 DDL 锁住。核对截至切换时已提交的来源和旧余额，差异交核对，不补写账户。
LOCK TABLE meton_ledger.accounts, meton_ledger.events IN SHARE MODE;
DO $audit$
BEGIN
    IF EXISTS (SELECT FROM public.meton_s1_funds_births b
        JOIN public.users u ON u.id=b.remote_user
        LEFT JOIN public.meton_managed_creations m ON m.operation=b.operation AND m.remote_user=b.remote_user
        LEFT JOIN meton_ledger.accounts a ON a.source_marker=m.source_marker
        LEFT JOIN meton_ledger.events e ON e.source_marker=a.source_marker AND e.sequence=a.last_sequence
        WHERE b.operation IS NOT NULL AND (m.operation IS NULL OR b.had_source_event<>(a.source_marker IS NOT NULL)
            OR (a.source_marker IS NOT NULL AND e.event_id IS NULL) OR u.balance<>coalesce(e.balance_after,0)
            OR u.frozen_balance<>0 OR u.total_recharged<>0))
        OR EXISTS (SELECT FROM meton_ledger.accounts a WHERE NOT EXISTS (
            SELECT FROM public.meton_managed_creations m JOIN public.meton_s1_funds_births b
                ON b.operation=m.operation AND b.remote_user=m.remote_user WHERE m.source_marker=a.source_marker)) THEN
        RAISE EXCEPTION 'original managed funds require reconciliation' USING ERRCODE='23514';
    END IF;
END $audit$;

-- 保留 S1 对原身份、活动及无资金证明的逐项检验，以及原函数身份和执行授权。
-- 新赠送也须复验保护配置，已有购买来源的账号同样不能跳过。历史原凭证仍可独立查询。
DO $definition$
DECLARE
    state_definition text:=pg_get_functiondef('public.meton_s1_funds_state(text,text,bigint,uuid)'::regprocedure);
    grant_definition text:=pg_get_functiondef('meton_ledger.redeem_registration(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,text,text)'::regprocedure);
    old_mode constant text:='t.tgenabled=''O''';
    balance_guard constant text:='(''users'',''meton_s1_no_native_balance'')';
    first_rule constant text:='SELECT * INTO policy FROM meton_ledger.registration_rules';
    issue_receipt constant text:='RETURN QUERY SELECT * FROM meton_ledger.find_registration';
BEGIN
    IF cardinality(string_to_array(state_definition,old_mode))<>2 OR cardinality(string_to_array(state_definition,balance_guard))<>2
        OR cardinality(string_to_array(grant_definition,first_rule))<>2 OR cardinality(string_to_array(grant_definition,issue_receipt))<>2 THEN
        RAISE EXCEPTION 'unexpected managed funding definition';
    END IF;
    EXECUTE replace(replace(state_definition,old_mode,'t.tgenabled=''A'''),balance_guard,
        balance_guard||',(''user_provider_default_grants'',''meton_s2_no_first_bind''),(''meton_s1_funds_births'',''meton_s2_primary_birth'')');
    grant_definition:=replace(grant_definition,first_rule,$check$IF NOT EXISTS (
        SELECT FROM public.meton_s1_funds_state(p_env,p_source,p_epoch,p_creation)
        WHERE state IN ('controlled_empty','funds_or_activity')) THEN
        RAISE EXCEPTION 'native funding guards unavailable' USING ERRCODE='55000';
    END IF;
    $check$||first_rule);
    -- 只有首笔发放需要原生码仍在场。其后码可依保留期清除，重复查询始终认原永久凭证。
    EXECUTE replace(grant_definition,issue_receipt,$proof$IF effect.posting_xid<>pg_current_xact_id() OR NOT EXISTS (
        SELECT FROM meton_ledger.registration_grants g JOIN meton_ledger.outbox o ON o.event_id=g.event_id
        JOIN public.redeem_codes c ON c.id=g.native_code_id AND c.code=g.business_code
        JOIN public.users u ON u.id=c.used_by
        JOIN public.meton_s1_funds_births b ON b.remote_user=u.id AND b.operation=p_creation AND b.had_source_event
        WHERE g.event_id=effect.event_id AND g.source_marker=p_marker AND g.eligibility=p_grant AND u.id=p_remote
            AND c.type='meton_initial' AND c.status='used' AND c.value=effect.amount AND c.used_at=effect.recorded_at
            AND u.balance=effect.balance_after) THEN
        RAISE EXCEPTION 'registration funding effects incomplete' USING ERRCODE='23514';
    END IF;
    $proof$||issue_receipt);
END $definition$;
