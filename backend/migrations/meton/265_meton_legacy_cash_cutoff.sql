-- 保存当时存在的原现金、退款和兑换证据。金额归类及真实支付均不由本次冻结执行。
CREATE TABLE meton_ledger.legacy_cash_manifests (
    cutoff uuid PRIMARY KEY REFERENCES meton_ledger.legacy_balance_fences,
    captured_xid xid8 NOT NULL, captured_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE meton_ledger.legacy_cash_facts (
    cutoff uuid NOT NULL REFERENCES meton_ledger.legacy_cash_manifests,
    kind text NOT NULL CHECK (kind IN ('order','redemption','order_audit')),
    native_id bigint NOT NULL, proof jsonb NOT NULL CHECK(jsonb_typeof(proof)='object'),
    PRIMARY KEY(cutoff,kind,native_id)
);
CREATE TRIGGER immutable_manifest BEFORE UPDATE OR DELETE ON meton_ledger.legacy_cash_manifests
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.legacy_cash_manifests ENABLE ALWAYS TRIGGER immutable_manifest;
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.legacy_cash_facts
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.legacy_cash_facts ENABLE ALWAYS TRIGGER immutable_fact;

-- 订单号、履约码可先于归属行出现。每个引用使用一个真实数据库版本；旧快照等锁后须重新读取，不能凭看不见归属越过冻结。
CREATE TABLE meton_ledger.legacy_native_references (
    reference text PRIMARY KEY, writer_xid xid8 NOT NULL
);
CREATE FUNCTION meton_ledger.legacy_hash(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp AS $$
    SELECT encode(sha256(convert_to(p_value,'UTF8')),'hex')
$$;
CREATE FUNCTION meton_ledger.native_order_id(p_value text) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp AS $$
    SELECT CASE WHEN p_value ~ '^[1-9][0-9]{0,18}$' AND
        (length(p_value)<19 OR p_value COLLATE "C"<='9223372036854775807') THEN p_value::bigint END
$$;
CREATE INDEX meton_legacy_order_recharge_code ON public.payment_orders(lower(btrim(recharge_code)))
    WHERE btrim(recharge_code)<>'';

CREATE FUNCTION meton_ledger.lock_native_references(p_refs text[]) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE item text;
BEGIN
    FOR item IN SELECT DISTINCT r FROM unnest(p_refs) r WHERE r IS NOT NULL ORDER BY r LOOP
        INSERT INTO meton_ledger.legacy_native_references AS v VALUES(item,pg_current_xact_id())
            ON CONFLICT(reference) DO UPDATE SET writer_xid=excluded.writer_xid WHERE v.writer_xid<>excluded.writer_xid;
    END LOOP;
END $$;
CREATE FUNCTION meton_ledger.check_legacy_native_users(p_users bigint[]) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE locked record;
BEGIN
    -- 已有关联且早于 S1 建号的用户即使还没冻结也要取共享行锁，否则冻结会漏掉先开始的旧事务。
    FOR locked IN SELECT u.id,u.meton_legacy_balance_fence FROM public.users u JOIN public.meton_managed_creations m ON m.remote_user=u.id
        WHERE u.id=ANY(p_users) AND (u.meton_legacy_balance_fence IS NOT NULL OR
            NOT EXISTS(SELECT FROM public.meton_s1_funds_births b WHERE b.remote_user=u.id))
        ORDER BY u.id FOR SHARE OF u LOOP
        IF locked.meton_legacy_balance_fence IS NOT NULL THEN
            RAISE EXCEPTION 'original funds are frozen for reconciliation' USING ERRCODE='23514'; END IF;
    END LOOP;
END $$;

CREATE FUNCTION meton_ledger.guard_legacy_cash() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE owners bigint[]; orders bigint[]; codes text[]; tokens text[];
BEGIN
    CASE TG_TABLE_NAME
    WHEN 'payment_orders' THEN
        IF TG_OP<>'INSERT' THEN owners:=array_append(owners,OLD.user_id); orders:=array_append(orders,OLD.id); codes:=array_append(codes,OLD.recharge_code); END IF;
        IF TG_OP<>'DELETE' THEN owners:=array_append(owners,NEW.user_id); orders:=array_append(orders,NEW.id); codes:=array_append(codes,NEW.recharge_code); END IF;
    WHEN 'redeem_codes' THEN
        IF TG_OP<>'INSERT' THEN owners:=array_append(owners,OLD.used_by); codes:=array_append(codes,OLD.code); END IF;
        IF TG_OP<>'DELETE' THEN owners:=array_append(owners,NEW.used_by); codes:=array_append(codes,NEW.code); END IF;
    WHEN 'payment_audit_logs' THEN
        IF TG_OP<>'INSERT' THEN orders:=array_append(orders,meton_ledger.native_order_id(OLD.order_id)); END IF;
        IF TG_OP<>'DELETE' THEN orders:=array_append(orders,meton_ledger.native_order_id(NEW.order_id)); END IF;
    ELSE RAISE EXCEPTION 'unexpected cash table';
    END CASE;
    codes:=ARRAY(SELECT DISTINCT lower(btrim(c)) FROM unnest(codes) c WHERE btrim(c)<>'');
    tokens:=ARRAY(SELECT 'cash/order/'||id FROM unnest(orders) id UNION ALL
                  SELECT 'cash/code/'||meton_ledger.legacy_hash(c) FROM unnest(codes) c);
    PERFORM meton_ledger.lock_native_references(tokens);
    PERFORM meton_ledger.check_legacy_native_users(ARRAY(
        SELECT u FROM unnest(owners) u UNION SELECT o.user_id FROM public.payment_orders o WHERE o.id=ANY(orders)
        UNION SELECT o.user_id FROM public.payment_orders o WHERE btrim(o.recharge_code)<>'' AND lower(btrim(o.recharge_code))=ANY(codes)
        UNION SELECT r.used_by FROM public.redeem_codes r WHERE lower(btrim(r.code))=ANY(codes)));
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION meton_ledger.deny_legacy_truncate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR EXISTS(SELECT FROM meton_ledger.legacy_balance_fences) THEN
        RAISE EXCEPTION 'cutover evidence prevents table-wide cleanup' USING ERRCODE='23514'; END IF;
    RETURN NULL;
END $$;
DO $install$
DECLARE tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['payment_orders','redeem_codes','payment_audit_logs'] LOOP
        EXECUTE format('CREATE TRIGGER meton_legacy_cash BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_legacy_cash()',tbl);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER meton_legacy_cash',tbl);
        EXECUTE format('CREATE TRIGGER meton_keep_cash_before_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION meton_ledger.deny_legacy_truncate()',tbl);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER meton_keep_cash_before_truncate',tbl);
    END LOOP;
END $install$;

CREATE FUNCTION meton_ledger.capture_legacy_cash() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    -- 持原用户行锁后以新快照读先提交的子表事务。老的可重复读快照可能没有看到先提交的孤立审计行。
    IF current_setting('transaction_isolation')<>'read committed' OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'fresh primary snapshot required' USING ERRCODE='55000'; END IF;
    IF NEW.cutoff_xid<>pg_current_xact_id() OR NOT EXISTS(SELECT FROM public.users WHERE id=NEW.remote_user AND meton_legacy_balance_fence=NEW.cutoff) THEN
        RAISE EXCEPTION 'cash facts must share the original balance transaction' USING ERRCODE='23514'; END IF;
    INSERT INTO meton_ledger.legacy_cash_manifests(cutoff,captured_xid) VALUES(NEW.cutoff,NEW.cutoff_xid);
    INSERT INTO meton_ledger.legacy_cash_facts
        SELECT NEW.cutoff,'order',o.id,jsonb_build_object('state',o.status,'order_type',o.order_type,'credit_amount',o.amount::text,
            'order_pay_amount',o.pay_amount::text,'bonus',o.bonus_amount::text,'reported_refund',o.refund_amount::text,
            'fee_rate',o.fee_rate::text,'forced_refund',o.force_refund,'created_at',o.created_at,'paid_at',o.paid_at,'completed_at',o.completed_at,
            'refund_requested_at',o.refund_requested_at,'refund_at',o.refund_at,'provider_key',o.provider_key,'provider_instance',o.provider_instance_id,
            'currency_evidence',CASE WHEN o.provider_snapshot->>'currency' ~ '^[A-Z]{3}$' THEN o.provider_snapshot->>'currency' END,
            'trade_ref',meton_ledger.legacy_hash(nullif(o.payment_trade_no,'')),'merchant_ref',meton_ledger.legacy_hash(nullif(o.out_trade_no,'')),
            'code_ref',meton_ledger.legacy_hash(nullif(o.recharge_code,'')),'redemption_match',
            CASE WHEN btrim(o.recharge_code)='' THEN 'none' WHEN r.matches=0 THEN 'missing' WHEN r.matches<>1 THEN 'ambiguous'
                 WHEN NOT r.exact_match THEN 'different_spelling' WHEN r.owned_used THEN 'owned_used' WHEN r.unclaimed THEN 'unclaimed' ELSE 'unverified_owner' END)
        FROM public.payment_orders o CROSS JOIN LATERAL (
            SELECT count(*) AS matches,bool_or(c.code=o.recharge_code) AS exact_match,
                bool_or(c.used_by=NEW.remote_user AND c.status='used') AS owned_used,bool_or(c.used_by IS NULL AND c.status='unused') AS unclaimed
            FROM public.redeem_codes c WHERE btrim(o.recharge_code)<>'' AND lower(btrim(c.code))=lower(btrim(o.recharge_code))
        ) r WHERE o.user_id=NEW.remote_user;
    INSERT INTO meton_ledger.legacy_cash_facts
        SELECT NEW.cutoff,'redemption',c.id,jsonb_build_object('code_ref',meton_ledger.legacy_hash(c.code),'type',c.type,
            'value',c.value::text,'state',c.status,'used_at',c.used_at,'created_at',c.created_at,'expires_at',c.expires_at)
        FROM public.redeem_codes c WHERE c.used_by=NEW.remote_user;
    -- 审计原文可能含付款链接或客户资料。仅保留原行引用、动作和内容摘要，现金仍须回原渠道核对。
    INSERT INTO meton_ledger.legacy_cash_facts
        SELECT NEW.cutoff,'order_audit',l.id,jsonb_build_object('order_id',o.id,'action',
            CASE WHEN l.action ~ '^[A-Z][A-Z0-9_]{0,49}$' THEN l.action ELSE 'unrecognized' END,
            'detail_digest',meton_ledger.legacy_hash(l.detail),'created_at',l.created_at)
        FROM public.payment_orders o JOIN public.payment_audit_logs l ON l.order_id=o.id::text WHERE o.user_id=NEW.remote_user;
    RETURN NEW;
END $$;
-- 同表的 AFTER 触发器按名称执行；须在 mark_legacy_balance 确认可见之后快照。
CREATE TRIGGER zz_capture_legacy_cash AFTER INSERT ON meton_ledger.legacy_balance_fences
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.capture_legacy_cash();
ALTER TABLE meton_ledger.legacy_balance_fences ENABLE ALWAYS TRIGGER zz_capture_legacy_cash;

CREATE FUNCTION meton_ledger.legacy_cash_guards_ready() RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT EXISTS (
        SELECT FROM (
            SELECT tbl,n,p,events FROM unnest(ARRAY['public.payment_orders','public.payment_audit_logs','public.redeem_codes']::regclass[]) tbl
                CROSS JOIN (VALUES('meton_legacy_cash','meton_ledger.guard_legacy_cash()'::regprocedure,31),
                    ('meton_keep_cash_before_truncate','meton_ledger.deny_legacy_truncate()'::regprocedure,34)) x(n,p,events)
            UNION ALL VALUES ('meton_ledger.legacy_balance_fences'::regclass,'zz_capture_legacy_cash','meton_ledger.capture_legacy_cash()'::regprocedure,5),
                ('meton_ledger.legacy_cash_facts'::regclass,'immutable_fact','meton_ledger.keep_event()'::regprocedure,27),
                ('meton_ledger.legacy_cash_manifests'::regclass,'immutable_manifest','meton_ledger.keep_event()'::regprocedure,27)
        ) expected WHERE NOT EXISTS(SELECT FROM pg_trigger t WHERE t.tgrelid=expected.tbl AND t.tgname=expected.n AND t.tgfoid=expected.p
            AND t.tgenabled='A' AND t.tgtype=expected.events AND t.tgqual IS NULL AND t.tgnargs=0 AND t.tgattr=''::int2vector))
$$;
DO $guard$
DECLARE original text:=pg_get_functiondef('meton_ledger.freeze_legacy_balance(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid)'::regprocedure);
    gate constant text:='IF NOT meton_ledger.legacy_balance_guard_ready() THEN';
BEGIN
    IF cardinality(string_to_array(original,gate))<>2 OR NOT meton_ledger.legacy_cash_guards_ready() THEN
        RAISE EXCEPTION 'unexpected cutover protections'; END IF;
    EXECUTE replace(original,gate,$access$IF has_parameter_privilege(session_user,'session_replication_role','SET,ALTER SYSTEM')
        OR EXISTS(SELECT FROM unnest(ARRAY['public.payment_orders','public.redeem_codes','public.payment_audit_logs','public.meton_s1_funds_births']::regclass[]) t
            WHERE has_any_column_privilege(session_user,t,'INSERT,UPDATE') OR has_table_privilege(session_user,t,'DELETE,TRUNCATE,TRIGGER')) THEN
            RAISE EXCEPTION 'cutover role must not write original evidence' USING ERRCODE='42501'; END IF;
        IF NOT meton_ledger.legacy_balance_guard_ready() OR NOT meton_ledger.legacy_cash_guards_ready() THEN$access$);
END $guard$;

CREATE FUNCTION meton_ledger.find_legacy_cash(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT original||jsonb_build_object('cash_state',CASE WHEN NOT meton_ledger.legacy_cash_guards_ready() THEN 'cash_guards_unavailable'
        WHEN m.cutoff IS NULL THEN 'cash_history_before_guards_unverified' ELSE 'cash_evidence_frozen' END,
        'balance_awaiting_classification',b.cutoff_balance::text,
        'cash_handoff',CASE WHEN m.cutoff IS NOT NULL AND meton_ledger.legacy_cash_guards_ready() THEN
            (SELECT jsonb_build_object('orders',count(*),'payment_in_progress',count(*) FILTER(WHERE proof->>'state' IN ('PENDING','PAID','RECHARGING')),
                'refund_in_progress',count(*) FILTER(WHERE proof->>'state' IN ('REFUND_REQUESTED','REFUNDING','REFUND_PENDING','REFUND_FAILED')),
                'reported_refunds',count(*) FILTER(WHERE proof->>'state' IN ('REFUNDED','PARTIALLY_REFUNDED')),
                'unknown_status',count(*) FILTER(WHERE proof->>'state' NOT IN ('PENDING','PAID','RECHARGING','COMPLETED','EXPIRED','CANCELLED','FAILED',
                    'REFUND_REQUESTED','REFUNDING','REFUND_PENDING','REFUND_FAILED','REFUNDED','PARTIALLY_REFUNDED')))
             FROM meton_ledger.legacy_cash_facts WHERE cutoff=p_cutoff AND kind='order') END,
        'cash_counts',CASE WHEN m.cutoff IS NOT NULL AND meton_ledger.legacy_cash_guards_ready() THEN
            (SELECT coalesce(jsonb_object_agg(kind,n),'{}'::jsonb) FROM (SELECT kind,count(*) n FROM meton_ledger.legacy_cash_facts
                WHERE cutoff=p_cutoff GROUP BY kind) groups) END)
    FROM meton_ledger.find_legacy_balance_fence(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff) original
    JOIN meton_ledger.legacy_balance_fences b ON b.cutoff=p_cutoff
    LEFT JOIN meton_ledger.legacy_cash_manifests m ON m.cutoff=b.cutoff AND m.captured_xid=b.cutoff_xid WHERE original IS NOT NULL
$$;
CREATE FUNCTION meton_ledger.list_legacy_cash_facts(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid,p_kind text,p_after bigint,p_limit integer)
RETURNS TABLE(native_id bigint,proof jsonb) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT f.native_id,f.proof FROM meton_ledger.legacy_cash_facts f WHERE f.cutoff=p_cutoff AND f.kind=p_kind AND f.native_id>p_after
        AND p_after>=0 AND p_limit BETWEEN 1 AND 100 AND meton_ledger.legacy_cash_guards_ready()
        AND EXISTS(SELECT FROM meton_ledger.legacy_cash_manifests m JOIN meton_ledger.legacy_balance_fences b USING(cutoff)
                   WHERE m.cutoff=p_cutoff AND m.captured_xid=b.cutoff_xid)
        AND meton_ledger.find_legacy_balance_fence(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff) IS NOT NULL
        ORDER BY f.native_id LIMIT greatest(0,least(100,p_limit))
$$;
REVOKE ALL ON TABLE meton_ledger.legacy_cash_manifests,meton_ledger.legacy_cash_facts,meton_ledger.legacy_native_references FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.legacy_hash(text),meton_ledger.native_order_id(text),meton_ledger.lock_native_references(text[]),
    meton_ledger.check_legacy_native_users(bigint[]),meton_ledger.guard_legacy_cash(),meton_ledger.deny_legacy_truncate(),
    meton_ledger.capture_legacy_cash(),meton_ledger.legacy_cash_guards_ready(),
    meton_ledger.find_legacy_cash(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid),
    meton_ledger.list_legacy_cash_facts(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,bigint,integer) FROM PUBLIC;
