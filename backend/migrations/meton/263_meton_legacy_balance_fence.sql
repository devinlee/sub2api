-- 为早于 S1 零资金建号证明的托管账号设置逐账号余额栅栏。设置栅栏不分类旧余额，也不开放消费或退款。
ALTER TABLE public.users ADD COLUMN meton_legacy_balance_fence uuid;
CREATE TABLE meton_ledger.legacy_balance_fences (
    cutoff uuid PRIMARY KEY CHECK(cutoff<>'00000000-0000-0000-0000-000000000000'),
    source_marker uuid NOT NULL UNIQUE REFERENCES public.meton_managed_creations(source_marker),
    remote_user bigint NOT NULL UNIQUE REFERENCES public.users(id),
    cut_epoch bigint NOT NULL CHECK(cut_epoch>0), cutoff_balance numeric NOT NULL, cutoff_frozen numeric NOT NULL, cutoff_recharged numeric NOT NULL,
    cutoff_xid xid8 NOT NULL DEFAULT pg_current_xact_id(), recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER immutable_fence BEFORE UPDATE OR DELETE ON meton_ledger.legacy_balance_fences
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.legacy_balance_fences ENABLE ALWAYS TRIGGER immutable_fence;

CREATE FUNCTION meton_ledger.guard_legacy_native_balance() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        IF OLD.meton_legacy_balance_fence IS NOT NULL THEN RAISE EXCEPTION 'historical funds require reconciliation' USING ERRCODE='23514'; END IF;
        RETURN OLD;
    END IF;
    IF TG_OP='INSERT' THEN
        IF NEW.meton_legacy_balance_fence IS NOT NULL THEN RAISE EXCEPTION 'no inherited cutover' USING ERRCODE='23514'; END IF;
        RETURN NEW;
    END IF;
    IF OLD.meton_legacy_balance_fence IS NULL THEN
        IF NEW.meton_legacy_balance_fence IS NULL THEN RETURN NEW; END IF;
        IF pg_trigger_depth()>1 AND EXISTS (SELECT FROM meton_ledger.legacy_balance_fences f WHERE f.cutoff=NEW.meton_legacy_balance_fence
            AND f.remote_user=OLD.id AND f.cutoff_xid=pg_current_xact_id() AND (f.cutoff_balance,f.cutoff_frozen,f.cutoff_recharged)=(OLD.balance,OLD.frozen_balance,OLD.total_recharged))
            AND (OLD.id,OLD.balance,OLD.frozen_balance,OLD.total_recharged)=(NEW.id,NEW.balance,NEW.frozen_balance,NEW.total_recharged) THEN RETURN NEW; END IF;
        RAISE EXCEPTION 'cutover must capture the original account' USING ERRCODE='23514';
    END IF;
    -- 标记在旧进程要更新的同一行。等锁后 READ COMMITTED 看新行，更早的可重复读事务则发生序列化冲突。
    IF ROW(NEW.meton_legacy_balance_fence,NEW.id,NEW.balance,NEW.frozen_balance,NEW.total_recharged,NEW.email,NEW.password_hash,NEW.role,NEW.restrict_public_groups)
        IS DISTINCT FROM ROW(OLD.meton_legacy_balance_fence,OLD.id,OLD.balance,OLD.frozen_balance,OLD.total_recharged,OLD.email,OLD.password_hash,OLD.role,OLD.restrict_public_groups)
        OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'historical balance frozen at cutoff' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_legacy_native_money BEFORE INSERT OR UPDATE OR DELETE ON public.users FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_legacy_native_balance();
-- 旧同步账号即使还能切换 session_replication_role，也不能绕开已冻结的余额行。
ALTER TABLE public.users ENABLE ALWAYS TRIGGER meton_legacy_native_money;

CREATE FUNCTION meton_ledger.mark_legacy_balance() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    UPDATE public.users SET meton_legacy_balance_fence=NEW.cutoff WHERE id=NEW.remote_user AND meton_legacy_balance_fence IS NULL
        AND (balance,frozen_balance,total_recharged)=(NEW.cutoff_balance,NEW.cutoff_frozen,NEW.cutoff_recharged);
    IF NOT FOUND THEN RAISE EXCEPTION 'cutoff balance changed' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER mark_legacy_balance AFTER INSERT ON meton_ledger.legacy_balance_fences FOR EACH ROW EXECUTE FUNCTION meton_ledger.mark_legacy_balance();
ALTER TABLE meton_ledger.legacy_balance_fences ENABLE ALWAYS TRIGGER mark_legacy_balance;

CREATE FUNCTION meton_ledger.legacy_balance_guard_ready() RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT EXISTS (SELECT FROM (VALUES('public.users'::regclass,'meton_legacy_native_money','meton_ledger.guard_legacy_native_balance()'::regprocedure),
        ('meton_ledger.legacy_balance_fences'::regclass,'mark_legacy_balance','meton_ledger.mark_legacy_balance()'::regprocedure),
        ('meton_ledger.legacy_balance_fences'::regclass,'immutable_fence','meton_ledger.keep_event()'::regprocedure)) t(tbl,name,proc)
        WHERE NOT EXISTS(SELECT FROM pg_trigger g WHERE g.tgrelid=t.tbl AND g.tgname=t.name AND g.tgfoid=t.proc AND g.tgenabled='A'))
$$;

CREATE FUNCTION meton_ledger.find_legacy_balance_fence(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('state','balance_frozen_needs_reconciliation','environment',m.environment,'source',m.source,'user',m.meton_user,'account',m.account,
        'creation',m.operation,'dispatch',m.dispatch,'remote_user',b.remote_user,'source_marker',b.source_marker,'cutoff',b.cutoff,'cut_epoch',b.cut_epoch,
        'balance',b.cutoff_balance::text,'frozen',b.cutoff_frozen::text,'total_recharged',b.cutoff_recharged::text)
    FROM public.meton_managed_fence f JOIN public.meton_managed_creations m ON (m.environment,m.source,m.epoch)=(f.environment,f.source,f.epoch)
        JOIN meton_ledger.legacy_balance_fences b ON (b.source_marker,b.remote_user)=(m.source_marker,m.remote_user)
        JOIN public.users u ON (u.id,u.meton_legacy_balance_fence)=(b.remote_user,b.cutoff)
    WHERE f.singleton AND f.enabled AND (f.environment,f.source,f.epoch)=(p_env,p_source,p_epoch) AND
        (m.operation,m.meton_user,m.account,m.dispatch,m.remote_user,m.source_marker,b.cutoff)=(p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff)
        AND (u.balance,u.frozen_balance,u.total_recharged)=(b.cutoff_balance,b.cutoff_frozen,b.cutoff_recharged)
        AND meton_ledger.legacy_balance_guard_ready() AND NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
$$;
CREATE FUNCTION meton_ledger.freeze_legacy_balance(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
    p_remote bigint,p_marker uuid,p_cutoff uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE original jsonb; native public.users%ROWTYPE;
BEGIN
    IF pg_has_role(session_user,current_user,'MEMBER') OR EXISTS(SELECT FROM pg_roles r WHERE
        (r.rolsuper OR r.rolcreaterole OR r.rolreplication OR r.rolname IN ('pg_write_all_data','pg_execute_server_program','pg_write_server_files'))
        AND pg_has_role(session_user,r.oid,'MEMBER')) OR has_schema_privilege(session_user,'meton_ledger','CREATE')
        OR EXISTS (SELECT FROM pg_class t WHERE t.relkind='r' AND (t.relnamespace='meton_ledger'::regnamespace
            OR t.oid IN ('public.users'::regclass,'public.meton_managed_fence'::regclass,'public.meton_managed_creations'::regclass))
            AND (has_any_column_privilege(session_user,t.oid,'INSERT,UPDATE') OR has_table_privilege(session_user,t.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted cutover authority required' USING ERRCODE='42501'; END IF;
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND (environment,source,epoch)=(p_env,p_source,p_epoch) FOR SHARE;
    IF NOT FOUND OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'source unavailable' USING ERRCODE='55000'; END IF;
    IF p_cutoff IS NULL OR p_cutoff='00000000-0000-0000-0000-000000000000' THEN RAISE EXCEPTION 'missing cutover' USING ERRCODE='22023'; END IF;
    SELECT u.* INTO native FROM public.meton_managed_creations m JOIN public.users u ON u.id=m.remote_user
        WHERE (m.environment,m.source,m.epoch,m.operation,m.meton_user,m.account,m.dispatch,m.remote_user,m.source_marker)
            =(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker)
            AND u.email='meton-'||p_account::text||'@managed.invalid' AND u.password_hash='!meton-managed' AND u.role='user' AND u.restrict_public_groups
        FOR SHARE OF m FOR UPDATE OF u;
    IF NOT FOUND THEN RAISE EXCEPTION 'wrong original historical account' USING ERRCODE='42501'; END IF;
    IF NOT meton_ledger.legacy_balance_guard_ready() THEN
        RAISE EXCEPTION 'cutover protections unavailable' USING ERRCODE='55000'; END IF;
    original:=meton_ledger.find_legacy_balance_fence(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff);
    IF original IS NOT NULL THEN RETURN original; END IF;
    IF EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=p_remote)
        OR EXISTS(SELECT FROM meton_ledger.accounts WHERE source_marker=p_marker) THEN RAISE EXCEPTION 'not an unclassified legacy account' USING ERRCODE='55000'; END IF;
    IF native.meton_legacy_balance_fence IS NOT NULL THEN RAISE EXCEPTION 'different original cutoff' USING ERRCODE='23505'; END IF;
    INSERT INTO meton_ledger.legacy_balance_fences(cutoff,source_marker,remote_user,cut_epoch,cutoff_balance,cutoff_frozen,cutoff_recharged)
        VALUES(p_cutoff,p_marker,p_remote,p_epoch,native.balance,native.frozen_balance,native.total_recharged);
    original:=meton_ledger.find_legacy_balance_fence(p_env,p_source,p_epoch,p_creation,p_user,p_account,p_dispatch,p_remote,p_marker,p_cutoff);
    IF original IS NULL THEN RAISE EXCEPTION 'incomplete cutover' USING ERRCODE='23514'; END IF;
    RETURN original;
END $$;
REVOKE ALL ON TABLE meton_ledger.legacy_balance_fences FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.guard_legacy_native_balance(),meton_ledger.mark_legacy_balance(),meton_ledger.legacy_balance_guard_ready(),
    meton_ledger.find_legacy_balance_fence(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid),
    meton_ledger.freeze_legacy_balance(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid) FROM PUBLIC;
