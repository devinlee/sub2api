-- 来源管理者另行发布已核实的换算版本。安装迁移不发放额度，不自动启用任何生产规则。
CREATE TABLE meton_ledger.registration_rules (
    environment text NOT NULL, source text NOT NULL, version text NOT NULL CHECK(version ~ '^[A-Za-z0-9_.-]{1,120}$'),
    unit text NOT NULL CHECK(unit ~ '^[A-Za-z0-9_.-]{1,120}$'),
    rate numeric(20,8) NOT NULL CHECK(rate>0 AND rate<=199999999999.99999999),
    PRIMARY KEY(environment,source,version)
);
CREATE TRIGGER immutable_rule BEFORE UPDATE OR DELETE ON meton_ledger.registration_rules
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TABLE meton_ledger.registration_grants (
    event_id uuid PRIMARY KEY REFERENCES meton_ledger.events,
    source_marker uuid NOT NULL UNIQUE REFERENCES meton_ledger.accounts,
    eligibility uuid NOT NULL UNIQUE, business_code text NOT NULL UNIQUE CHECK(business_code=replace(eligibility::text,'-','')),
    native_code_id bigint NOT NULL UNIQUE CHECK(native_code_id>0)
);
-- 原生码可以按保留周期删除，永久凭证不能随码、幂等缓存或当前会话删除。
CREATE TRIGGER immutable_grant BEFORE UPDATE OR DELETE ON meton_ledger.registration_grants
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE INDEX meton_registration_native_code ON public.redeem_codes(lower(btrim(code)));
ALTER FUNCTION meton_ledger.credit_origin(text,text,bigint,uuid,uuid,uuid,uuid,text,uuid,text,text,text,text,text,text) SECURITY INVOKER;

CREATE FUNCTION meton_ledger.record_used_code() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    INSERT INTO public.redeem_codes(id,code,type,value,status,used_by,used_at)
        SELECT NEW.native_code_id,NEW.business_code,'meton_initial',e.amount,'used',m.remote_user,e.recorded_at
        FROM meton_ledger.events e JOIN public.meton_managed_creations m USING(source_marker)
        WHERE e.event_id=NEW.event_id AND e.source_marker=NEW.source_marker AND e.kind='grant' AND e.origin_ref=NEW.eligibility
            AND e.operation_id=NEW.eligibility AND e.posting_xid=pg_current_xact_id();
    IF NOT FOUND THEN RAISE EXCEPTION 'original credit not in this transaction' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER record_used_code AFTER INSERT ON meton_ledger.registration_grants FOR EACH ROW EXECUTE FUNCTION meton_ledger.record_used_code();

-- 旧原生调用即使尝试先清空 used_by 或改成另一种码也无权修改。仅允许原事务写一次已用的内部码。
CREATE FUNCTION public.meton_s2_guard_redeem() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF lower(btrim(NEW.code)) ~ '^[0-9a-f]{32}$' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(lower(btrim(NEW.code)),256));
    END IF;
    IF TG_OP='UPDATE' AND (OLD.type='meton_initial' OR EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=OLD.used_by)) THEN
        RAISE EXCEPTION 'managed code immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.type='meton_initial' OR EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=NEW.used_by)
        OR EXISTS(SELECT FROM meton_ledger.registration_grants WHERE business_code=lower(btrim(NEW.code))) THEN
        IF TG_OP='INSERT' AND pg_trigger_depth()>1 AND NEW.status='used' AND NEW.type='meton_initial' AND NEW.group_id IS NULL AND NEW.expires_at IS NULL AND EXISTS(
            SELECT FROM meton_ledger.registration_grants g JOIN meton_ledger.events e USING(event_id)
            JOIN public.meton_managed_creations m ON m.source_marker=g.source_marker
            WHERE g.native_code_id=NEW.id AND g.business_code=NEW.code AND e.amount=NEW.value AND m.remote_user=NEW.used_by
                AND e.posting_xid=pg_current_xact_id() AND NEW.used_at=e.recorded_at) THEN RETURN NEW; END IF;
        RAISE EXCEPTION 'native redemption unavailable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER meton_s1_no_redeem BEFORE INSERT OR UPDATE ON public.redeem_codes FOR EACH ROW EXECUTE FUNCTION public.meton_s2_guard_redeem();
CREATE TRIGGER meton_s2_no_first_bind BEFORE INSERT OR UPDATE ON public.user_provider_default_grants
    FOR EACH ROW EXECUTE FUNCTION public.meton_s1_deny_fund_row('user_id');

CREATE TYPE meton_ledger.registration_receipt AS (
    meton_user uuid, account uuid, creation uuid, dispatch uuid, remote_user bigint, source_marker uuid,
    eligibility uuid, business_code text, event_id uuid, native_code_id bigint, rule text, unit text, amount text
);
CREATE FUNCTION meton_ledger.find_registration(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_grant uuid)
RETURNS SETOF meton_ledger.registration_receipt LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT m.meton_user,m.account,m.operation,m.dispatch,m.remote_user,m.source_marker,g.eligibility,g.business_code,e.event_id,g.native_code_id,
           l.rule_version,a.unit,e.amount::text FROM public.meton_managed_fence f JOIN public.meton_managed_creations m
           ON m.environment=f.environment AND m.source=f.source AND m.epoch=f.epoch
           JOIN meton_ledger.registration_grants g ON g.source_marker=m.source_marker
           JOIN meton_ledger.events e ON e.event_id=g.event_id AND e.source_marker=m.source_marker AND e.origin_ref=g.eligibility AND e.kind='grant'
           JOIN meton_ledger.lots l ON l.credit_event=e.event_id JOIN meton_ledger.accounts a ON a.source_marker=m.source_marker
    WHERE f.singleton AND f.enabled AND f.environment=p_env AND f.source=p_source AND f.epoch=p_epoch AND m.operation=p_creation AND g.eligibility=p_grant
      AND NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
$$;
CREATE FUNCTION meton_ledger.redeem_registration(p_env text,p_source text,p_epoch bigint,p_creation uuid,p_user uuid,p_account uuid,p_dispatch uuid,
        p_remote bigint,p_marker uuid,p_grant uuid,p_rule text,p_unit text,p_amount text)
RETURNS SETOF meton_ledger.registration_receipt LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    old meton_ledger.registration_receipt; policy meton_ledger.registration_rules%ROWTYPE; effect meton_ledger.events%ROWTYPE;
    original_code text:=replace(p_grant::text,'-','');
BEGIN
    -- 旧安装常用表所有者连接。该身份可以关闭触发器，不满足来源模式的开工条件。
    IF pg_has_role(session_user,current_user,'MEMBER') OR EXISTS(SELECT FROM pg_roles r WHERE
        (r.rolsuper OR r.rolcreaterole OR r.rolreplication OR r.rolname IN ('pg_write_all_data','pg_execute_server_program','pg_write_server_files'))
        AND pg_has_role(session_user,r.oid,'MEMBER')) OR EXISTS(SELECT FROM pg_class t WHERE t.relnamespace='meton_ledger'::regnamespace AND t.relkind='r'
            AND (has_any_column_privilege(session_user,t.oid,'INSERT,UPDATE') OR has_table_privilege(session_user,t.oid,'DELETE,TRUNCATE,TRIGGER')))
        OR has_schema_privilege(session_user,'meton_ledger','CREATE') THEN
        RAISE EXCEPTION 'restricted runtime required' USING ERRCODE='42501';
    END IF;
    PERFORM 1 FROM public.meton_managed_fence f WHERE f.singleton AND f.enabled AND f.environment=p_env AND f.source=p_source AND f.epoch=p_epoch FOR SHARE;
    IF NOT FOUND OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'source unavailable' USING ERRCODE='55000';
    END IF;
    PERFORM 1 FROM public.meton_managed_creations m JOIN public.users u ON u.id=m.remote_user JOIN public.meton_s1_funds_births b ON b.operation=m.operation AND b.remote_user=u.id
        WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND m.operation=p_creation AND m.meton_user=p_user AND m.account=p_account
            AND m.dispatch=p_dispatch AND m.remote_user=p_remote AND m.source_marker=p_marker AND u.status='active' AND u.deleted_at IS NULL
        FOR UPDATE OF u FOR SHARE OF m;
    IF NOT FOUND THEN RAISE EXCEPTION 'wrong original target' USING ERRCODE='42501'; END IF;
    SELECT * INTO old FROM meton_ledger.find_registration(p_env,p_source,p_epoch,p_creation,p_grant);
    IF FOUND THEN
        IF ROW(old.rule,old.unit,old.amount) IS DISTINCT FROM ROW(p_rule,p_unit,p_amount) THEN RAISE EXCEPTION 'grant replay conflict' USING ERRCODE='23505'; END IF;
        RETURN NEXT old; RETURN;
    END IF;
    SELECT * INTO policy FROM meton_ledger.registration_rules WHERE environment=p_env AND source=p_source AND version=p_rule;
    IF NOT FOUND OR p_grant IS NULL OR p_grant='00000000-0000-0000-0000-000000000000'::uuid OR p_unit IS DISTINCT FROM policy.unit
        OR p_amount IS DISTINCT FROM (5*policy.rate)::numeric(20,8)::text THEN RAISE EXCEPTION 'unpublished grant or amount' USING ERRCODE='22023'; END IF;
    -- 旧码、旧赠送或已用资格都交核对。已有原生入账不能被包装成新的来源再发一次。
    PERFORM pg_advisory_xact_lock(hashtextextended(original_code,256));
    IF EXISTS(SELECT FROM public.redeem_codes r WHERE lower(btrim(r.code))=original_code)
        OR EXISTS(SELECT FROM meton_ledger.events WHERE source_marker=p_marker AND kind='grant') THEN
        RAISE EXCEPTION 'prior grant requires reconciliation' USING ERRCODE='23505';
    END IF;
    SELECT * INTO STRICT effect FROM meton_ledger.credit_origin(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_grant,'grant',p_grant,
        policy.unit,policy.version,'CNY','5.00000000',policy.rate::text,p_amount);
    INSERT INTO meton_ledger.registration_grants VALUES(effect.event_id,p_marker,p_grant,original_code,nextval(pg_get_serial_sequence('public.redeem_codes','id')));
    RETURN QUERY SELECT * FROM meton_ledger.find_registration(p_env,p_source,p_epoch,p_creation,p_grant);
    IF NOT FOUND THEN RAISE EXCEPTION 'original grant receipt missing' USING ERRCODE='23514'; END IF;
END $$;
REVOKE ALL ON TABLE meton_ledger.registration_rules,meton_ledger.registration_grants FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.redeem_registration(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,text,text),
    meton_ledger.find_registration(text,text,bigint,uuid,uuid),meton_ledger.record_used_code(),public.meton_s2_guard_redeem() FROM PUBLIC;
