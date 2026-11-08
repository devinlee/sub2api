-- 只由托管来源的迁移身份安装。报价和权限初始为空，发布价格与开放模型入口由各自的阶段负责。
CREATE TABLE meton_ledger.text_prices (
    environment text NOT NULL, source text NOT NULL, protocol text NOT NULL CHECK (protocol IN ('responses','chat_completions')),
    model text NOT NULL CHECK (model ~ '^[A-Za-z0-9_./:-]{1,160}$'),
    version text NOT NULL CHECK (version ~ '^[A-Za-z0-9_.-]{1,120}$'), unit text NOT NULL CHECK (unit ~ '^[A-Za-z0-9_.-]{1,120}$'),
    input_per_million numeric(20,8) NOT NULL, cached_per_million numeric(20,8) NOT NULL, output_per_million numeric(20,8) NOT NULL,
    multiplier numeric(20,8) NOT NULL, max_input integer NOT NULL CHECK (max_input>0), max_output integer NOT NULL CHECK (max_output>0),
    CHECK (input_per_million BETWEEN 0 AND 999999999999.99999999 AND cached_per_million BETWEEN 0 AND 999999999999.99999999
        AND output_per_million BETWEEN 0 AND 999999999999.99999999 AND multiplier>0 AND multiplier<=999999999999.99999999),
    PRIMARY KEY (environment,source,protocol,model,version)
);
CREATE TRIGGER immutable_text_price BEFORE UPDATE OR DELETE ON meton_ledger.text_prices
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TABLE meton_ledger.active_text_prices (
    environment text NOT NULL, source text NOT NULL, protocol text NOT NULL, model text NOT NULL, version text NOT NULL,
    PRIMARY KEY (environment,source,protocol,model),
    FOREIGN KEY (environment,source,protocol,model,version) REFERENCES meton_ledger.text_prices
);

CREATE TABLE meton_ledger.text_requests (
    request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_marker uuid NOT NULL REFERENCES meton_ledger.accounts, caller text NOT NULL CHECK (caller IN ('meton.chat.v1','meton.oc07.v1')),
    operation_id uuid NOT NULL CHECK (operation_id<>'00000000-0000-0000-0000-000000000000'), UNIQUE (source_marker,caller,operation_id),
    environment text NOT NULL, source text NOT NULL, protocol text NOT NULL, model text NOT NULL, price_version text NOT NULL,
    digest_version integer NOT NULL CHECK (digest_version=1), input_digest text NOT NULL CHECK (input_digest ~ '^[a-f0-9]{64}$'),
    input_bound integer NOT NULL CHECK (input_bound>=0), output_bound integer NOT NULL CHECK (output_bound>0),
    quote numeric(20,8) NOT NULL CHECK (quote>0 AND quote<=999999999999.99999999), epoch_at_accept bigint NOT NULL CHECK (epoch_at_accept>0),
    origin_key uuid NOT NULL REFERENCES public.meton_managed_keys(operation), accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    accepting_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    FOREIGN KEY (environment,source,protocol,model,price_version) REFERENCES meton_ledger.text_prices
);
CREATE TABLE meton_ledger.text_allocations (
    request_id uuid NOT NULL REFERENCES meton_ledger.text_requests, ordinal integer NOT NULL CHECK (ordinal>0),
    credit_event uuid NOT NULL REFERENCES meton_ledger.lots, amount numeric(20,8) NOT NULL CHECK (amount>0 AND amount<=999999999999.99999999),
    PRIMARY KEY (request_id,ordinal), UNIQUE (request_id,credit_event)
);
-- 没有这行才是尚未取得发送权。取消与取得发送权互斥，查询和重复领取不能交出新的发送资格。
CREATE TABLE meton_ledger.text_send_decisions (
    request_id uuid PRIMARY KEY REFERENCES meton_ledger.text_requests, state text NOT NULL CHECK (state IN ('cancelled_unsent','dispatch_claimed')),
    decided_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER immutable_text_request BEFORE UPDATE OR DELETE ON meton_ledger.text_requests FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TRIGGER immutable_text_allocation BEFORE UPDATE OR DELETE ON meton_ledger.text_allocations FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TRIGGER immutable_text_decision BEFORE UPDATE OR DELETE ON meton_ledger.text_send_decisions FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();

CREATE FUNCTION meton_ledger.check_text_allocation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT FROM meton_ledger.text_requests r JOIN meton_ledger.events e ON e.source_marker=r.source_marker
        WHERE r.request_id=NEW.request_id AND e.event_id=NEW.credit_event AND r.accepting_xid=pg_current_xact_id()) THEN
        RAISE EXCEPTION 'allocation outside original owner or transaction' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER text_allocation_owner BEFORE INSERT ON meton_ledger.text_allocations FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_text_allocation();
CREATE FUNCTION meton_ledger.check_text_quote() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NEW.quote IS DISTINCT FROM (SELECT sum(amount) FROM meton_ledger.text_allocations WHERE request_id=NEW.request_id) THEN
        RAISE EXCEPTION 'text quote lacks its complete allocation' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER complete_text_quote AFTER INSERT ON meton_ledger.text_requests DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_text_quote();

-- 所有资金写者按同一原用户行排序。业务库、Redis 和网关都不持有这把锁，也没有来源表写权。
CREATE FUNCTION meton_ledger.lock_text_owner(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid)
RETURNS bigint LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE remote_id bigint;
BEGIN
    IF pg_has_role(session_user,current_user,'MEMBER') OR EXISTS (SELECT FROM pg_roles r WHERE
        (r.rolsuper OR r.rolcreaterole OR r.rolreplication OR r.rolname IN ('pg_write_all_data','pg_execute_server_program','pg_write_server_files'))
        AND pg_has_role(session_user,r.oid,'MEMBER')) OR has_schema_privilege(session_user,'meton_ledger','CREATE')
        OR EXISTS (SELECT FROM pg_class t WHERE t.relkind='r' AND (t.relnamespace='meton_ledger'::regnamespace OR t.oid IN
           ('public.meton_managed_fence'::regclass,'public.meton_managed_creations'::regclass,'public.meton_managed_keys'::regclass,
            'public.meton_managed_key_retirements'::regclass,'public.meton_managed_session_closures'::regclass,'public.api_keys'::regclass,'public.users'::regclass))
           AND (has_any_column_privilege(session_user,t.oid,'INSERT,UPDATE') OR has_table_privilege(session_user,t.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted text runtime required' USING ERRCODE='42501';
    END IF;
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND environment=p_env AND source=p_source AND epoch=p_epoch FOR SHARE;
    IF NOT FOUND OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'source unavailable' USING ERRCODE='55000';
    END IF;
    SELECT m.remote_user INTO remote_id FROM public.meton_managed_creations m JOIN public.users u ON u.id=m.remote_user
        JOIN public.meton_s1_funds_births b ON b.operation=m.operation AND b.remote_user=u.id
        WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND m.source_marker=p_marker AND m.meton_user=p_user AND m.account=p_account
          AND u.role='user' AND u.restrict_public_groups AND u.password_hash='!meton-managed' AND u.email='meton-'||p_account::text||'@managed.invalid'
        FOR SHARE OF m FOR UPDATE OF u;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown text owner' USING ERRCODE='42501'; END IF;
    RETURN remote_id;
END $$;

CREATE FUNCTION meton_ledger.lock_text_key(p_env text,p_source text,p_epoch bigint,p_remote bigint,p_key bigint,p_hash text)
RETURNS uuid LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE signature uuid;
BEGIN
    -- 撤销同样锁原 api_keys 行。拿到锁后再读撤销依据，同时按实际时间复验等待期间是否已到期。
    SELECT x.operation INTO signature FROM public.meton_managed_keys x JOIN public.api_keys k ON k.id=x.remote_key
        WHERE k.id=p_key AND k.user_id=p_remote FOR SHARE OF k;
    IF NOT FOUND OR NOT public.meton_current_key(p_env,p_source,p_epoch,p_key,p_remote,p_hash)
        OR NOT EXISTS (SELECT FROM public.api_keys WHERE id=p_key AND expires_at>clock_timestamp()) THEN
        RAISE EXCEPTION 'managed session no longer current' USING ERRCODE='42501';
    END IF;
    RETURN signature;
END $$;

CREATE TYPE meton_ledger.text_hold_receipt AS (
    request_id uuid, environment text, source text, meton_user uuid, account uuid, source_marker uuid, caller text, operation_id uuid, protocol text, model text,
    digest_version integer, input_digest text, epoch_at_accept bigint, price_version text, unit text, input_bound integer, output_bound integer,
    quote text, state text, allocations jsonb
);
CREATE FUNCTION meton_ledger.find_text_hold(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid)
RETURNS SETOF meton_ledger.text_hold_receipt LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT r.request_id,r.environment,r.source,m.meton_user,m.account,r.source_marker,r.caller,r.operation_id,r.protocol,r.model,r.digest_version,r.input_digest,r.epoch_at_accept,
           r.price_version,p.unit,r.input_bound,r.output_bound,r.quote::text,coalesce(d.state,'prepared'),
           (SELECT jsonb_agg(jsonb_build_object('credit_event',a.credit_event,'kind',e.kind,'sequence',e.sequence,'amount',a.amount::text) ORDER BY a.ordinal)
            FROM meton_ledger.text_allocations a JOIN meton_ledger.events e ON e.event_id=a.credit_event WHERE a.request_id=r.request_id)
    FROM public.meton_managed_fence f JOIN public.meton_managed_creations m ON m.environment=f.environment AND m.source=f.source AND m.epoch=f.epoch
    JOIN meton_ledger.text_requests r ON r.source_marker=m.source_marker AND r.environment=m.environment AND r.source=m.source
    JOIN meton_ledger.text_prices p ON (p.environment,p.source,p.protocol,p.model,p.version)=(r.environment,r.source,r.protocol,r.model,r.price_version)
    LEFT JOIN meton_ledger.text_send_decisions d USING(request_id)
    WHERE f.singleton AND f.enabled AND f.environment=p_env AND f.source=p_source AND f.epoch=p_epoch AND m.meton_user=p_user AND m.account=p_account
        AND r.source_marker=p_marker AND r.caller=p_caller AND r.operation_id=p_operation
        AND NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
$$;

CREATE FUNCTION meton_ledger.reserve_text(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_key bigint,p_hash text,p_protocol text,p_model text,p_digest_version integer,p_digest text,p_input integer,p_output integer)
RETURNS meton_ledger.text_hold_receipt LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    remote_id bigint; signature uuid; receipt meton_ledger.text_hold_receipt; price meton_ledger.text_prices%ROWTYPE;
    native_amount numeric; source_total numeric; source_unit text; required numeric; unfilled numeric; part numeric;
    ref uuid; line_no integer:=0; lot record;
BEGIN
    remote_id:=meton_ledger.lock_text_owner(p_env,p_source,p_epoch,p_user,p_account,p_marker);
    signature:=meton_ledger.lock_text_key(p_env,p_source,p_epoch,remote_id,p_key,p_hash);
    IF num_nulls(p_caller,p_operation,p_protocol,p_model,p_digest_version,p_digest,p_input,p_output)>0 OR p_operation='00000000-0000-0000-0000-000000000000'
        OR p_caller NOT IN ('meton.chat.v1','meton.oc07.v1') OR p_protocol NOT IN ('responses','chat_completions')
        OR p_model !~ '^[A-Za-z0-9_./:-]{1,160}$' OR p_digest_version<>1 OR p_digest !~ '^[a-f0-9]{64}$' OR p_input<0 OR p_output<1 THEN
        RAISE EXCEPTION 'invalid original text intent or unbounded quote' USING ERRCODE='22023';
    END IF;
    SELECT * INTO receipt FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF FOUND THEN
        IF ROW(receipt.protocol,receipt.model,receipt.digest_version,receipt.input_digest,receipt.input_bound,receipt.output_bound)
            IS DISTINCT FROM ROW(p_protocol,p_model,p_digest_version,p_digest,p_input,p_output) THEN
            RAISE EXCEPTION 'original text intent conflicts' USING ERRCODE='23505';
        END IF;
        RETURN receipt;
    END IF;
    SELECT p.* INTO price FROM meton_ledger.active_text_prices a JOIN meton_ledger.text_prices p USING(environment,source,protocol,model,version)
        WHERE a.environment=p_env AND a.source=p_source AND a.protocol=p_protocol AND a.model=p_model FOR SHARE OF a;
    IF NOT FOUND OR p_input>price.max_input OR p_output>price.max_output THEN RAISE EXCEPTION 'text price or execution bounds unavailable' USING ERRCODE='55000'; END IF;
    -- 未知命中率按较贵的输入价上界，倍率只乘一次。先按整数最小单位上取整，避免数值除法提前截断。
    required:=ceil((p_input*greatest(price.input_per_million,price.cached_per_million)+p_output*price.output_per_million)*price.multiplier*100)*0.00000001;
    IF required<=0 OR required>999999999999.99999999 THEN RAISE EXCEPTION 'text quote unavailable' USING ERRCODE='22003'; END IF;
    SELECT balance INTO native_amount FROM public.users WHERE id=remote_id AND frozen_balance=0;
    SELECT coalesce(sum(l.remaining),0) INTO source_total FROM meton_ledger.events e JOIN meton_ledger.lots l ON l.credit_event=e.event_id WHERE e.source_marker=p_marker;
    SELECT unit INTO source_unit FROM meton_ledger.accounts WHERE source_marker=p_marker;
    IF source_total IS DISTINCT FROM native_amount OR (source_unit IS NOT NULL AND source_unit<>price.unit) THEN
        RAISE EXCEPTION 'source total or unit requires reconciliation' USING ERRCODE='23514';
    END IF;
    IF source_unit IS NULL OR required>source_total THEN RAISE EXCEPTION 'insufficient available funds' USING ERRCODE='P5301'; END IF;
    INSERT INTO meton_ledger.text_requests(source_marker,caller,operation_id,environment,source,protocol,model,price_version,digest_version,input_digest,
        input_bound,output_bound,quote,epoch_at_accept,origin_key)
        VALUES(p_marker,p_caller,p_operation,p_env,p_source,p_protocol,p_model,price.version,p_digest_version,p_digest,p_input,p_output,required,p_epoch,signature)
        RETURNING request_id INTO ref;
    unfilled:=required;
    FOR lot IN SELECT l.credit_event,l.remaining-l.held-l.refund_held AS available FROM meton_ledger.events e JOIN meton_ledger.lots l ON l.credit_event=e.event_id
        WHERE e.source_marker=p_marker AND l.remaining>l.held+l.refund_held ORDER BY (e.kind='grant') DESC,e.sequence FOR UPDATE OF l LOOP
        part:=least(unfilled,lot.available);
        IF part>0 THEN
            UPDATE meton_ledger.lots SET held=held+part WHERE credit_event=lot.credit_event;
            line_no:=line_no+1;
            INSERT INTO meton_ledger.text_allocations VALUES(ref,line_no,lot.credit_event,part);
            unfilled:=unfilled-part;
        END IF;
        EXIT WHEN unfilled=0;
    END LOOP;
    IF unfilled<>0 THEN RAISE EXCEPTION 'insufficient available funds' USING ERRCODE='P5301'; END IF;
    SELECT * INTO STRICT receipt FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    RETURN receipt;
END $$;

CREATE FUNCTION meton_ledger.cancel_unsent_text(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid)
RETURNS SETOF meton_ledger.text_hold_receipt LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE receipt meton_ledger.text_hold_receipt;
BEGIN
    PERFORM meton_ledger.lock_text_owner(p_env,p_source,p_epoch,p_user,p_account,p_marker);
    SELECT * INTO receipt FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR receipt.request_id IS DISTINCT FROM p_request THEN RETURN; END IF;
    IF receipt.epoch_at_accept<>p_epoch THEN RAISE EXCEPTION 'restored hold requires reconciliation' USING ERRCODE='55000'; END IF;
    IF receipt.state='prepared' THEN
        INSERT INTO meton_ledger.text_send_decisions(request_id,state) VALUES(p_request,'cancelled_unsent');
        UPDATE meton_ledger.lots l SET held=held-a.amount FROM meton_ledger.text_allocations a
            WHERE a.request_id=p_request AND a.credit_event=l.credit_event;
        receipt.state:='cancelled_unsent';
    END IF;
    RETURN NEXT receipt;
END $$;

-- 只返回本事务首次领取的结果；提交不明、被取消或已有领取都不能据查询补发。真实出站由 S2-11 接此函数。
CREATE FUNCTION meton_ledger.claim_text_dispatch(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
    p_request uuid,p_key bigint,p_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE remote_id bigint; signature uuid;
BEGIN
    remote_id:=meton_ledger.lock_text_owner(p_env,p_source,p_epoch,p_user,p_account,p_marker);
    signature:=meton_ledger.lock_text_key(p_env,p_source,p_epoch,remote_id,p_key,p_hash);
    INSERT INTO meton_ledger.text_send_decisions(request_id,state)
        SELECT r.request_id,'dispatch_claimed' FROM meton_ledger.text_requests r
        WHERE r.request_id=p_request AND r.source_marker=p_marker AND r.caller=p_caller AND r.operation_id=p_operation
            AND r.epoch_at_accept=p_epoch AND r.origin_key=signature
        ON CONFLICT(request_id) DO NOTHING;
    RETURN FOUND;
END $$;

REVOKE ALL ON TABLE meton_ledger.text_prices,meton_ledger.active_text_prices,meton_ledger.text_requests,meton_ledger.text_allocations,meton_ledger.text_send_decisions FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.check_text_allocation(),meton_ledger.check_text_quote(),meton_ledger.lock_text_owner(text,text,bigint,uuid,uuid,uuid),meton_ledger.lock_text_key(text,text,bigint,bigint,bigint,text),
    meton_ledger.find_text_hold(text,text,bigint,uuid,uuid,uuid,text,uuid),meton_ledger.reserve_text(text,text,bigint,uuid,uuid,uuid,text,uuid,bigint,text,text,text,integer,text,integer,integer),
    meton_ledger.cancel_unsent_text(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid),meton_ledger.claim_text_dispatch(text,text,bigint,uuid,uuid,uuid,text,uuid,uuid,bigint,text) FROM PUBLIC;
