-- 只由托管来源的迁移身份安装；此迁移不授权业务角色、不建账户、不导入历史余额。
CREATE SCHEMA meton_ledger;
REVOKE ALL ON SCHEMA meton_ledger FROM PUBLIC;
CREATE TABLE meton_ledger.accounts (
    source_marker uuid PRIMARY KEY REFERENCES public.meton_managed_creations(source_marker),
    unit text NOT NULL CHECK (unit ~ '^[A-Za-z0-9_.-]{1,120}$'),
    last_sequence bigint NOT NULL CHECK (last_sequence > 0)
);
CREATE TABLE meton_ledger.events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    environment text NOT NULL, source text NOT NULL,
    source_marker uuid NOT NULL REFERENCES meton_ledger.accounts,
    operation_id uuid NOT NULL, kind text NOT NULL CHECK (kind IN ('grant','purchase')),
    origin_ref uuid NOT NULL, sequence bigint NOT NULL CHECK (sequence > 0),
    amount numeric(20,8) NOT NULL CHECK (amount > 0 AND amount <= 999999999999.99999999),
    balance_before numeric(20,8) NOT NULL CHECK (balance_before >= 0),
    balance_after numeric(20,8) NOT NULL CHECK (balance_after = balance_before + amount AND balance_after <= 999999999999.99999999),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(), posting_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    UNIQUE (environment,source,operation_id), UNIQUE (environment,source,kind,origin_ref), UNIQUE (source_marker,sequence)
);
CREATE TABLE meton_ledger.lots (
    credit_event uuid PRIMARY KEY REFERENCES meton_ledger.events,
    rule_version text NOT NULL, denomination text NOT NULL, face_value numeric(20,8) NOT NULL,
    conversion_rate numeric(20,8) NOT NULL, refundable boolean NOT NULL,
    remaining numeric(20,8) NOT NULL, held numeric(20,8) NOT NULL DEFAULT 0, refund_held numeric(20,8) NOT NULL DEFAULT 0,
    CHECK (face_value > 0 AND conversion_rate > 0 AND face_value <= 999999999999.99999999 AND conversion_rate <= 999999999999.99999999),
    CHECK (held >= 0 AND refund_held >= 0 AND held + refund_held <= remaining AND remaining <= 999999999999.99999999),
    CHECK (refundable OR refund_held = 0)
);
CREATE TABLE meton_ledger.outbox (
    event_id uuid PRIMARY KEY REFERENCES meton_ledger.events,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- 在事务末尾再检查来源和投递事实。中途故障不能留下单独的资金事件。
ALTER TABLE meton_ledger.events ADD FOREIGN KEY (event_id) REFERENCES meton_ledger.lots(credit_event) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE meton_ledger.events ADD FOREIGN KEY (event_id) REFERENCES meton_ledger.outbox(event_id) DEFERRABLE INITIALLY DEFERRED;

-- 让既有 S1 只读角色仍从原出生记录取得结清依据。即使将来消费到零也不能开具「从未有资金」证明。
ALTER TABLE public.meton_s1_funds_births ADD COLUMN had_source_event boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.meton_s1_keep_birth() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF TG_OP='INSERT' AND pg_trigger_depth()>1 AND NEW.born_xid=pg_current_xact_id() AND NEW.operation IS NULL AND NOT NEW.had_source_event THEN RETURN NEW; END IF;
    IF TG_OP='UPDATE' AND pg_trigger_depth()>1 AND
        ROW(NEW.remote_user,NEW.born_xid,NEW.marker)=ROW(OLD.remote_user,OLD.born_xid,OLD.marker) THEN
        IF OLD.operation IS NULL AND NEW.operation IS NOT NULL AND NEW.born_xid=pg_current_xact_id() AND NOT OLD.had_source_event AND NOT NEW.had_source_event THEN RETURN NEW; END IF;
        IF NEW.operation=OLD.operation AND NOT OLD.had_source_event AND NEW.had_source_event AND
            current_user=pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid='meton_ledger.events'::regclass)) AND
            EXISTS (SELECT FROM meton_ledger.events e JOIN public.meton_managed_creations m USING(source_marker)
                    WHERE m.operation=OLD.operation AND m.remote_user=OLD.remote_user AND e.sequence=1 AND e.posting_xid=pg_current_xact_id()) THEN RETURN NEW; END IF;
    END IF;
    RAISE EXCEPTION 'immutable funds origin' USING ERRCODE='23514';
END $$;
-- 保留 253 原函数的 OID、调用权限、只读执行身份和全部既有核验。原定义不匹配即整笔回滚迁移。
DO $migration$
DECLARE original text:=pg_get_functiondef('public.meton_s1_funds_state(text,text,bigint,uuid)'::regprocedure);
    predicate constant text:='CASE WHEN u.balance<>0';
BEGIN
    IF array_length(string_to_array(original,predicate),1)<>2 THEN RAISE EXCEPTION 'unexpected original funds check'; END IF;
    EXECUTE replace(original,predicate,'CASE WHEN b.had_source_event OR u.balance<>0');
END $migration$;

CREATE FUNCTION meton_ledger.apply_credit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    UPDATE public.users u SET balance=NEW.balance_after
        FROM public.meton_managed_creations m WHERE m.source_marker=NEW.source_marker AND m.remote_user=u.id AND u.balance=NEW.balance_before;
    IF NOT FOUND THEN RAISE EXCEPTION 'native balance mismatch' USING ERRCODE='23514'; END IF;
    IF NEW.sequence=1 THEN
        UPDATE public.meton_s1_funds_births b SET had_source_event=true FROM public.meton_managed_creations m
            WHERE m.source_marker=NEW.source_marker AND b.operation=m.operation AND NOT b.had_source_event;
        IF NOT FOUND THEN RAISE EXCEPTION 'source history mismatch' USING ERRCODE='23514'; END IF;
    END IF;
    INSERT INTO meton_ledger.outbox(event_id) VALUES(NEW.event_id);
    RETURN NEW;
END $$;
CREATE TRIGGER apply_credit AFTER INSERT ON meton_ledger.events FOR EACH ROW EXECUTE FUNCTION meton_ledger.apply_credit();

CREATE FUNCTION meton_ledger.keep_event() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'original credit is immutable' USING ERRCODE='23514';
END $$;
CREATE TRIGGER keep_event BEFORE UPDATE OR DELETE ON meton_ledger.events FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();

CREATE OR REPLACE FUNCTION public.meton_s1_deny_balance() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF ROW(NEW.balance,NEW.frozen_balance,NEW.total_recharged) IS NOT DISTINCT FROM ROW(OLD.balance,OLD.frozen_balance,OLD.total_recharged)
        OR NOT EXISTS (SELECT FROM public.meton_s1_funds_births WHERE remote_user=OLD.id) THEN RETURN NEW; END IF;
    -- 只放行同一事务的事件触发器，且归属、前后余额、冻结及现金旧值完全相符。会话变量不是授权。
    IF pg_trigger_depth() > 1 AND NEW.id=OLD.id AND NEW.frozen_balance=OLD.frozen_balance AND NEW.total_recharged=OLD.total_recharged THEN
        -- 单独的分支避免 PG 在处理原角色的一层更新时预解析其无权限的私有 schema。
        IF current_user=pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid='meton_ledger.events'::regclass)) AND
            EXISTS (SELECT FROM meton_ledger.events e JOIN public.meton_managed_creations m USING(source_marker)
            WHERE m.remote_user=OLD.id AND e.posting_xid=pg_current_xact_id() AND e.balance_before=OLD.balance AND e.balance_after=NEW.balance) THEN
            RETURN NEW;
        END IF;
    END IF;
    RAISE EXCEPTION 'managed funds disabled' USING ERRCODE='23514';
END $$;

CREATE FUNCTION meton_ledger.credit_origin(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,
    p_operation uuid,p_kind text,p_origin uuid,p_unit text,p_rule text,p_denomination text,p_face text,p_rate text,p_amount text)
RETURNS meton_ledger.events LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    creation public.meton_managed_creations%ROWTYPE; acct meton_ledger.accounts%ROWTYPE; previous meton_ledger.events%ROWTYPE;
    lot meton_ledger.lots%ROWTYPE; native_balance numeric; face numeric; rate numeric; amount numeric;
    number_pattern constant text := '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$';
BEGIN
    -- 先锁外部确认的当前代次，再核实原账户；重放旧事件也不能绕过代次及主体。
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND OR pg_is_in_recovery() OR current_setting('session_replication_role') <> 'origin' THEN
        RAISE EXCEPTION 'source unavailable' USING ERRCODE='55000';
    END IF;
    SELECT m.* INTO creation FROM public.meton_managed_creations m JOIN public.meton_s1_funds_births b
        ON b.remote_user=m.remote_user AND b.operation=m.operation
        WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND m.meton_user=p_user AND m.account=p_account AND m.source_marker=p_marker
        FOR SHARE OF m;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown managed origin' USING ERRCODE='42501'; END IF;
    IF num_nulls(p_operation,p_kind,p_origin,p_unit,p_rule,p_denomination,p_face,p_rate,p_amount)>0
        OR '00000000-0000-0000-0000-000000000000'::uuid IN (p_operation,p_origin) OR p_kind NOT IN ('grant','purchase')
        OR p_unit !~ '^[A-Za-z0-9_.-]{1,120}$' OR p_rule !~ '^[A-Za-z0-9_.-]{1,120}$' OR p_denomination !~ '^[A-Z]{3}$'
        OR p_face !~ number_pattern OR p_rate !~ number_pattern OR p_amount !~ number_pattern THEN
        RAISE EXCEPTION 'invalid source credit' USING ERRCODE='22023';
    END IF;
    face:=p_face::numeric; rate:=p_rate::numeric; amount:=p_amount::numeric;
    -- 原凭证已给定数量；无法在本版本精确表示的换算须先核对规则，数据库不得隐式舍入入账。
    IF face<=0 OR rate<=0 OR amount<=0 OR face*rate<>amount THEN RAISE EXCEPTION 'invalid conversion' USING ERRCODE='22023'; END IF;
    SELECT u.balance INTO native_balance FROM public.users u WHERE u.id=creation.remote_user AND u.status='active' AND u.deleted_at IS NULL
        AND u.email='meton-'||p_account::text||'@managed.invalid' AND u.password_hash='!meton-managed' AND u.restrict_public_groups AND u.role='user' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'inactive managed user' USING ERRCODE='42501'; END IF;
    SELECT * INTO acct FROM meton_ledger.accounts WHERE source_marker=p_marker;
    SELECT * INTO previous FROM meton_ledger.events WHERE environment=p_env AND source=p_source AND operation_id=p_operation;
    IF FOUND THEN
        SELECT * INTO STRICT lot FROM meton_ledger.lots WHERE credit_event=previous.event_id;
        IF ROW(previous.source_marker,previous.kind,previous.origin_ref,previous.amount,acct.unit,lot.rule_version,lot.denomination,lot.face_value,lot.conversion_rate)
            IS DISTINCT FROM ROW(p_marker,p_kind,p_origin,amount,p_unit,p_rule,p_denomination,face,rate) THEN
            RAISE EXCEPTION 'credit replay conflict' USING ERRCODE='23505';
        END IF;
        RETURN previous;
    END IF;
    IF acct.source_marker IS NULL THEN
        IF NOT EXISTS (SELECT FROM public.meton_s1_funds_state(p_env,p_source,p_epoch,creation.operation) WHERE state='controlled_empty') THEN
            RAISE EXCEPTION 'historical opening requires reconciliation' USING ERRCODE='55000';
        END IF;
        INSERT INTO meton_ledger.accounts VALUES(p_marker,p_unit,1) RETURNING * INTO acct;
    ELSE
        IF acct.unit<>p_unit OR NOT EXISTS (SELECT FROM meton_ledger.events WHERE source_marker=p_marker AND sequence=acct.last_sequence AND balance_after=native_balance) THEN
            RAISE EXCEPTION 'unit or balance mismatch' USING ERRCODE='23514';
        END IF;
        UPDATE meton_ledger.accounts SET last_sequence=last_sequence+1 WHERE source_marker=p_marker RETURNING * INTO acct;
    END IF;
    INSERT INTO meton_ledger.events(environment,source,source_marker,operation_id,kind,origin_ref,sequence,amount,balance_before,balance_after)
        VALUES(p_env,p_source,p_marker,p_operation,p_kind,p_origin,acct.last_sequence,amount,native_balance,native_balance+amount) RETURNING * INTO previous;
    INSERT INTO meton_ledger.lots(credit_event,rule_version,denomination,face_value,conversion_rate,refundable,remaining)
        VALUES(previous.event_id,p_rule,p_denomination,face,rate,p_kind='purchase',amount);
    RETURN previous;
END $$;

-- 提交后断线只查询原凭证。无结果始终是证据不足，不产生来源、派发或余额变动。
CREATE FUNCTION meton_ledger.find_credit(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_operation uuid)
RETURNS SETOF meton_ledger.events LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT e.* FROM public.meton_managed_fence f JOIN public.meton_managed_creations m
        ON f.environment=m.environment AND f.source=m.source AND f.epoch=m.epoch
        JOIN meton_ledger.events e ON e.source_marker=m.source_marker AND e.environment=m.environment AND e.source=m.source
        WHERE f.singleton AND f.enabled AND f.environment=p_env AND f.source=p_source AND f.epoch=p_epoch
            AND m.meton_user=p_user AND m.account=p_account AND m.source_marker=p_marker AND e.operation_id=p_operation
            AND NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
$$;
REVOKE ALL ON ALL TABLES IN SCHEMA meton_ledger FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA meton_ledger FROM PUBLIC;
