-- 同一截点保留旧费用、预扣、订阅和奖励记录，后续按原事实决定期初；本次不创建来源额度。
-- 上游撤销触发器原来依赖调用者的 search_path。受控事务使用受限搜索路径时，仍须把同一条失效通知写入原队列。
DO $cache$
DECLARE helper text:=pg_get_functiondef('public.enqueue_auth_cache_invalidation(text)'::regprocedure);
    emitter text:=pg_get_functiondef('public.enqueue_api_key_auth_cache_invalidation()'::regprocedure);
BEGIN
    IF cardinality(string_to_array(helper,'INSERT INTO auth_cache_invalidation_outbox'))<>2
        OR cardinality(string_to_array(emitter,'PERFORM enqueue_auth_cache_invalidation('))<>4 THEN
        RAISE EXCEPTION 'unexpected original key invalidation definition'; END IF;
    EXECUTE replace(helper,'INSERT INTO auth_cache_invalidation_outbox','INSERT INTO public.auth_cache_invalidation_outbox');
    EXECUTE replace(emitter,'PERFORM enqueue_auth_cache_invalidation(','PERFORM public.enqueue_auth_cache_invalidation(');
END $cache$;
ALTER FUNCTION public.enqueue_auth_cache_invalidation(text) SET search_path=pg_catalog,pg_temp;
ALTER FUNCTION public.enqueue_api_key_auth_cache_invalidation() SET search_path=pg_catalog,pg_temp;
ALTER TABLE public.api_keys ENABLE ALWAYS TRIGGER trg_api_keys_auth_cache_invalidation;

CREATE TABLE meton_ledger.legacy_activity_manifests (
    cutoff uuid PRIMARY KEY REFERENCES meton_ledger.legacy_balance_fences,
    captured_xid xid8 NOT NULL, captured_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE meton_ledger.legacy_activity_facts (
    cutoff uuid NOT NULL REFERENCES meton_ledger.legacy_activity_manifests,
    kind text NOT NULL, native_ref text NOT NULL, proof jsonb NOT NULL CHECK(jsonb_typeof(proof)='object'),
    PRIMARY KEY(cutoff,kind,native_ref)
);
CREATE TRIGGER immutable_manifest BEFORE UPDATE OR DELETE ON meton_ledger.legacy_activity_manifests
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.legacy_activity_manifests ENABLE ALWAYS TRIGGER immutable_manifest;
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.legacy_activity_facts
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.legacy_activity_facts ENABLE ALWAYS TRIGGER immutable_fact;

-- 字段白名单固定在迁移源码。保留资金、归属和状态，不保存 Key、原请求、提示词或第三方响应正文。
CREATE FUNCTION meton_ledger.legacy_activity_tables()
RETURNS TABLE(table_name text,key_fields text[],proof_fields text[]) LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
    VALUES
    ('api_keys',ARRAY['id'],ARRAY['id','user_id','status','created_at','expires_at','deleted_at']),
    ('usage_logs',ARRAY['id'],ARRAY['id','user_id','api_key_id','billing_type','total_cost','actual_cost','created_at']),
    ('billing_usage_entries',ARRAY['id'],ARRAY['id','usage_log_id','user_id','api_key_id','subscription_id','billing_type','applied','delta_usd','created_at']),
    ('usage_billing_dedup',ARRAY['request_id','api_key_id'],ARRAY['api_key_id','created_at']),
    ('usage_billing_dedup_archive',ARRAY['request_id','api_key_id'],ARRAY['api_key_id','created_at','archived_at']),
    ('user_subscriptions',ARRAY['id'],ARRAY['id','user_id','group_id','starts_at','expires_at','status','daily_usage_usd','weekly_usage_usd','monthly_usage_usd','deleted_at']),
    ('user_provider_default_grants',ARRAY['id'],ARRAY['id','user_id','provider_type','grant_reason','granted_at','created_at']),
    ('promo_code_usages',ARRAY['id'],ARRAY['id','user_id','promo_code_id','bonus_amount','used_at']),
    ('user_affiliates',ARRAY['user_id'],ARRAY['user_id','inviter_id','aff_quota','aff_history_quota','created_at']),
    ('user_affiliate_ledger',ARRAY['id'],ARRAY['id','user_id','source_user_id','action','amount','created_at']),
    ('user_allowed_groups',ARRAY['user_id','group_id'],ARRAY['user_id','group_id','created_at']),
    ('batch_image_jobs',ARRAY['id'],ARRAY['id','user_id','api_key_id','status','item_count','success_count','fail_count','cancelled_count','estimated_cost',
        'hold_amount','actual_cost','currency','version','created_at','submitted_at','started_at','finished_at','settled_at']),
    ('batch_image_items',ARRAY['id'],ARRAY['id','status','image_count','billed_amount','created_at','indexed_at']),
    ('batch_image_events',ARRAY['id'],ARRAY['id','event_type','created_at'])
$$;
CREATE FUNCTION meton_ledger.legacy_activity_users(p_table text,p_row jsonb)
RETURNS SETOF bigint LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT (p_row->>'user_id')::bigint WHERE p_table IN ('api_keys','usage_logs','billing_usage_entries','user_subscriptions',
        'user_provider_default_grants','promo_code_usages','user_affiliates','user_affiliate_ledger','user_allowed_groups','batch_image_jobs')
    UNION SELECT (p_row->>'inviter_id')::bigint WHERE p_table='user_affiliates'
    UNION SELECT (p_row->>'source_user_id')::bigint WHERE p_table='user_affiliate_ledger'
    UNION SELECT k.user_id FROM public.api_keys k WHERE k.id=(p_row->>'api_key_id')::bigint
        AND p_table IN ('usage_logs','billing_usage_entries','usage_billing_dedup','usage_billing_dedup_archive','batch_image_jobs')
    UNION SELECT l.user_id FROM public.usage_logs l WHERE l.id=(p_row->>'usage_log_id')::bigint AND p_table='billing_usage_entries'
    UNION SELECT s.user_id FROM public.user_subscriptions s WHERE s.id=(p_row->>'subscription_id')::bigint AND p_table='billing_usage_entries'
    UNION SELECT j.user_id FROM public.batch_image_jobs j WHERE j.batch_id=p_row->>'job_id' AND p_table IN ('batch_image_items','batch_image_events')
$$;
CREATE FUNCTION meton_ledger.legacy_activity_refs(p_table text,p_row jsonb)
RETURNS SETOF text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT 'activity/key/'||(p_row->>'id') WHERE p_table='api_keys'
    UNION SELECT 'activity/key/'||(p_row->>'api_key_id') WHERE p_table IN ('usage_logs','billing_usage_entries','usage_billing_dedup','usage_billing_dedup_archive','batch_image_jobs')
    UNION SELECT 'activity/usage/'||(p_row->>'id') WHERE p_table='usage_logs'
    UNION SELECT 'activity/usage/'||(p_row->>'usage_log_id') WHERE p_table='billing_usage_entries'
    UNION SELECT 'activity/subscription/'||(p_row->>'id') WHERE p_table='user_subscriptions'
    UNION SELECT 'activity/subscription/'||(p_row->>'subscription_id') WHERE p_table='billing_usage_entries'
    UNION SELECT 'activity/batch/'||meton_ledger.legacy_hash(p_row->>'batch_id') WHERE p_table='batch_image_jobs'
    UNION SELECT 'activity/batch/'||meton_ledger.legacy_hash(p_row->>'job_id') WHERE p_table IN ('batch_image_items','batch_image_events')
$$;
CREATE FUNCTION meton_ledger.guard_legacy_activity() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE before_row jsonb; after_row jsonb; owners bigint[];
BEGIN
    IF TG_OP<>'INSERT' THEN before_row:=to_jsonb(OLD); END IF;
    IF TG_OP<>'DELETE' THEN after_row:=to_jsonb(NEW); END IF;
    PERFORM meton_ledger.lock_native_references(ARRAY(
        SELECT r FROM meton_ledger.legacy_activity_refs(TG_TABLE_NAME,before_row) r
        UNION SELECT r FROM meton_ledger.legacy_activity_refs(TG_TABLE_NAME,after_row) r));
    owners:=ARRAY(SELECT u FROM meton_ledger.legacy_activity_users(TG_TABLE_NAME,before_row) u
        UNION SELECT u FROM meton_ledger.legacy_activity_users(TG_TABLE_NAME,after_row) u);
    IF TG_TABLE_NAME='api_keys' AND TG_OP='UPDATE' THEN
        -- 撤销仅缩短原凭据有效期并保留原归属，可与冻结共存；不能借撤销删除资金所依赖的 Key 或恢复旧身份。
        IF before_row-ARRAY['status','updated_at','expires_at','deleted_at']=after_row-ARRAY['status','updated_at','expires_at','deleted_at']
            AND NEW.status='inactive' AND (OLD.expires_at IS NULL OR NEW.expires_at<=OLD.expires_at)
            AND (OLD.deleted_at IS NULL OR NEW.deleted_at=OLD.deleted_at) THEN
            PERFORM 1 FROM public.users WHERE id=ANY(owners) ORDER BY id FOR SHARE;
            RETURN NEW;
        END IF;
    END IF;
    PERFORM meton_ledger.check_legacy_native_users(owners);
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
DO $install$
DECLARE item record;
BEGIN
    FOR item IN SELECT * FROM meton_ledger.legacy_activity_tables() LOOP
        EXECUTE format('CREATE TRIGGER meton_legacy_activity BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_legacy_activity()',item.table_name);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER meton_legacy_activity',item.table_name);
        EXECUTE format('CREATE TRIGGER meton_keep_activity_before_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION meton_ledger.deny_legacy_truncate()',item.table_name);
        EXECUTE format('ALTER TABLE public.%I ENABLE ALWAYS TRIGGER meton_keep_activity_before_truncate',item.table_name);
    END LOOP;
END $install$;
CREATE FUNCTION meton_ledger.capture_legacy_activity() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE item record;
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR current_setting('session_replication_role')<>'origin' OR
        NOT EXISTS(SELECT FROM meton_ledger.legacy_cash_manifests m WHERE m.cutoff=NEW.cutoff AND m.captured_xid=pg_current_xact_id()) THEN
        RAISE EXCEPTION 'activity requires the original cash cutoff transaction' USING ERRCODE='55000'; END IF;
    INSERT INTO meton_ledger.legacy_activity_manifests(cutoff,captured_xid) VALUES(NEW.cutoff,NEW.cutoff_xid);
    FOR item IN SELECT * FROM meton_ledger.legacy_activity_tables() LOOP
        EXECUTE format($capture$
            INSERT INTO meton_ledger.legacy_activity_facts
            SELECT $1,$2,meton_ledger.legacy_hash((SELECT jsonb_object_agg(k,j->k) FROM unnest($3::text[]) k)::text),
                (SELECT coalesce(jsonb_object_agg(k,CASE WHEN jsonb_typeof(v)='number' THEN to_jsonb(v#>>'{}') ELSE v END),'{}'::jsonb)
                 FROM jsonb_each(j) p(k,v) WHERE k=ANY($4)) ||
                (SELECT coalesce(jsonb_object_agg(k||'_ref',meton_ledger.legacy_hash(j->>k)),'{}'::jsonb)
                 FROM unnest(ARRAY['request_id','request_fingerprint','job_id','batch_id','hold_id','custom_id','event_hash','payload']) k WHERE j ? k)
            FROM (SELECT to_jsonb(r) j FROM public.%I r) source
            WHERE $5=ANY(ARRAY(SELECT uid FROM meton_ledger.legacy_activity_users($2,j) uid))
        $capture$,item.table_name) USING NEW.cutoff,item.table_name,item.key_fields,item.proof_fields,NEW.remote_user;
    END LOOP;
    -- 通用 HTTP 幂等表没有可核验的受益账号。保留全局未决引用供切换协调核对，不能当作本账号的一次成功或失败。
    INSERT INTO meton_ledger.legacy_activity_facts
        SELECT NEW.cutoff,'unassigned_idempotency',id::text,jsonb_build_object('scope_ref',meton_ledger.legacy_hash(scope),
            'key_ref',meton_ledger.legacy_hash(idempotency_key_hash),'fingerprint_ref',meton_ledger.legacy_hash(request_fingerprint),
            'state',status,'locked_until',locked_until,'expires_at',expires_at,'created_at',created_at)
        FROM public.idempotency_records WHERE status<>'succeeded';
    -- 源请求已开始发送时仍须保留其原费用证据。停用 Key 只关闭后续调用，不把已派发任务当成免费。
    UPDATE public.api_keys SET status='inactive',updated_at=clock_timestamp() WHERE user_id=NEW.remote_user AND status<>'inactive';
    RETURN NEW;
END $$;
CREATE TRIGGER zzz_capture_legacy_activity AFTER INSERT ON meton_ledger.legacy_balance_fences
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.capture_legacy_activity();
ALTER TABLE meton_ledger.legacy_balance_fences ENABLE ALWAYS TRIGGER zzz_capture_legacy_activity;
CREATE FUNCTION meton_ledger.legacy_activity_guards_ready() RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT EXISTS(SELECT FROM (
        SELECT ('public.'||table_name)::regclass tbl,n,p,events FROM meton_ledger.legacy_activity_tables()
            CROSS JOIN (VALUES('meton_legacy_activity','meton_ledger.guard_legacy_activity()'::regprocedure,31),
                ('meton_keep_activity_before_truncate','meton_ledger.deny_legacy_truncate()'::regprocedure,34)) t(n,p,events)
        UNION ALL VALUES ('meton_ledger.legacy_balance_fences'::regclass,'zzz_capture_legacy_activity','meton_ledger.capture_legacy_activity()'::regprocedure,5),
            ('meton_ledger.legacy_activity_facts'::regclass,'immutable_fact','meton_ledger.keep_event()'::regprocedure,27),
            ('meton_ledger.legacy_activity_manifests'::regclass,'immutable_manifest','meton_ledger.keep_event()'::regprocedure,27),
            ('public.api_keys'::regclass,'trg_api_keys_auth_cache_invalidation','public.enqueue_api_key_auth_cache_invalidation()'::regprocedure,25)
    ) expected WHERE NOT EXISTS(SELECT FROM pg_trigger t WHERE t.tgrelid=expected.tbl AND t.tgname=expected.n
        AND t.tgfoid=expected.p AND t.tgenabled='A' AND t.tgtype=expected.events AND t.tgqual IS NULL AND t.tgnargs=0 AND t.tgattr=''::int2vector))
$$;
DO $guard$
DECLARE original text:=pg_get_functiondef('meton_ledger.freeze_legacy_balance(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid)'::regprocedure);
    gate constant text:='IF NOT meton_ledger.legacy_balance_guard_ready() OR NOT meton_ledger.legacy_cash_guards_ready() THEN';
BEGIN
    IF cardinality(string_to_array(original,gate))<>2 OR NOT meton_ledger.legacy_activity_guards_ready() THEN
        RAISE EXCEPTION 'unexpected activity guards'; END IF;
    EXECUTE replace(original,gate,$access$IF EXISTS(SELECT FROM meton_ledger.legacy_activity_tables() t
        WHERE has_any_column_privilege(session_user,('public.'||t.table_name)::regclass,'INSERT,UPDATE')
            OR has_table_privilege(session_user,('public.'||t.table_name)::regclass,'DELETE,TRUNCATE,TRIGGER')) THEN
        RAISE EXCEPTION 'cutover role must not change activity evidence' USING ERRCODE='42501'; END IF;
    IF NOT meton_ledger.legacy_balance_guard_ready() OR NOT meton_ledger.legacy_cash_guards_ready() OR NOT meton_ledger.legacy_activity_guards_ready() THEN$access$);
END $guard$;
CREATE FUNCTION meton_ledger.find_legacy_activity(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT original||jsonb_build_object('activity_state',CASE WHEN NOT meton_ledger.legacy_activity_guards_ready() THEN 'activity_guards_unavailable'
        WHEN m.cutoff IS NULL THEN 'activity_history_before_guards_unverified' ELSE 'activity_evidence_frozen' END,
        'activity_counts',CASE WHEN m.cutoff IS NOT NULL AND meton_ledger.legacy_activity_guards_ready() THEN
            (SELECT coalesce(jsonb_object_agg(kind,n),'{}'::jsonb) FROM (SELECT kind,count(*) n FROM meton_ledger.legacy_activity_facts
                WHERE cutoff=p_cutoff GROUP BY kind) groups) END,
        'old_keys_inactive',NOT EXISTS(SELECT FROM public.api_keys WHERE user_id=p_remote AND status<>'inactive'))
    FROM meton_ledger.find_legacy_cash(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff) original
    JOIN meton_ledger.legacy_balance_fences b ON b.cutoff=p_cutoff
    LEFT JOIN meton_ledger.legacy_activity_manifests m ON m.cutoff=b.cutoff AND m.captured_xid=b.cutoff_xid WHERE original IS NOT NULL
$$;
CREATE FUNCTION meton_ledger.list_legacy_activity_facts(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid,p_kind text,p_after text,p_limit integer)
RETURNS TABLE(native_ref text,proof jsonb) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT f.native_ref,f.proof FROM meton_ledger.legacy_activity_facts f WHERE f.cutoff=p_cutoff AND f.kind=p_kind AND f.native_ref>p_after
        AND p_after IS NOT NULL AND p_limit BETWEEN 1 AND 100 AND meton_ledger.legacy_activity_guards_ready() AND meton_ledger.legacy_cash_guards_ready()
        AND EXISTS(SELECT FROM meton_ledger.legacy_activity_manifests m JOIN meton_ledger.legacy_balance_fences b USING(cutoff)
                   WHERE m.cutoff=p_cutoff AND m.captured_xid=b.cutoff_xid)
        AND meton_ledger.find_legacy_balance_fence(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff) IS NOT NULL
        ORDER BY f.native_ref LIMIT greatest(0,least(100,p_limit))
$$;
REVOKE ALL ON TABLE meton_ledger.legacy_activity_manifests,meton_ledger.legacy_activity_facts FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.legacy_activity_tables(),meton_ledger.legacy_activity_users(text,jsonb),
    meton_ledger.legacy_activity_refs(text,jsonb),meton_ledger.guard_legacy_activity(),meton_ledger.legacy_activity_guards_ready(),
    meton_ledger.capture_legacy_activity(),meton_ledger.find_legacy_activity(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid),
    meton_ledger.list_legacy_activity_facts(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,text,integer) FROM PUBLIC;
