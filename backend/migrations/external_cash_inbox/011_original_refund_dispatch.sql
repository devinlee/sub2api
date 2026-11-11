-- 资金原号、真实目标、发送/查询期限及签名响应放在来源恢复截点以外；换节点不能取得第二份发送秘密。
CREATE TABLE meton_inbox.refund_wire_bindings(
    refund uuid PRIMARY KEY, envelope jsonb NOT NULL, initial_mode text NOT NULL CHECK(initial_mode IN('claim','query')),
    channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,refund_number text NOT NULL, recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    UNIQUE(channel,cash_environment,merchant,refund_number)
);
CREATE TABLE meton_inbox.refund_wire_observations(
    refund uuid NOT NULL REFERENCES meton_inbox.refund_wire_bindings,method text NOT NULL CHECK(method IN ('POST','GET')),
    provider_state text NOT NULL CHECK(provider_state IN ('PROCESSING','SUCCESS','ABNORMAL','CLOSED')),receipt_hash bytea NOT NULL CHECK(octet_length(receipt_hash)=32),
    basis_hash bytea NOT NULL CHECK(octet_length(basis_hash)=32),fields jsonb NOT NULL, economic_hash bytea NOT NULL CHECK(octet_length(economic_hash)=32),
    key_ref text NOT NULL CHECK(length(key_ref) BETWEEN 1 AND 120),
    sealed bytea NOT NULL CHECK(octet_length(sealed) BETWEEN 29 AND 1572864),observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(refund,method,receipt_hash)
);
DO $p$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['refund_wire_bindings','refund_wire_observations'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
    END LOOP;
END $p$;
REVOKE ALL ON meton_inbox.refund_wire_bindings,meton_inbox.refund_wire_observations FROM PUBLIC;

CREATE FUNCTION meton_inbox.require_original_wire_sender(s jsonb) RETURNS meton_inbox.refund_gate_authorities
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities;
BEGIN
    SELECT * INTO a FROM meton_inbox.refund_gate_authorities WHERE (deployment,source,epoch,key_ref,source_system,sender)=
        (s->>'deployment',s->>'source',(s->>'epoch')::bigint,(s->>'keyRef')::uuid,s->>'sourceSystem',session_user) FOR SHARE;
    IF a.key_ref IS NULL OR s->>'inboxSystem' IS DISTINCT FROM meton_inbox.system_id() OR a.source_system=meton_inbox.system_id()
        OR pg_is_in_recovery() OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
        OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') OR current_setting('transaction_isolation')<>'read committed'
        OR current_setting('session_replication_role')<>'origin' OR pg_has_role(session_user,current_user,'MEMBER')
        OR has_schema_privilege(session_user,'meton_inbox','CREATE') OR EXISTS(SELECT FROM pg_roles r WHERE
            (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication) AND pg_has_role(session_user,r.oid,'MEMBER'))
        OR EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p')
            AND (has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE') OR has_table_privilege(session_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted current dispatch authority required' USING ERRCODE='42501'; END IF;
    RETURN a;
END $$;

-- 未分类的旧通知先等待索引。已明确属于另一笔交易的通知不会阻断本笔。
CREATE FUNCTION meton_inbox.original_refund_wire_risk(e jsonb) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE s jsonb:=e->'scope'; k jsonb:=e->'cash'; original_trade bytea;
BEGIN
    original_trade:=meton_inbox.lock_original_cash(s,k->>'order',k->>'transaction');
    IF EXISTS(SELECT FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant)=(s->>'channel',s->>'cashEnvironment',s->>'merchant')) OR
        EXISTS(SELECT FROM meton_inbox.refund_evidence i WHERE i.original=original_trade AND NOT EXISTS(
            SELECT FROM meton_inbox.refund_terminal_facts f WHERE (f.receipt,f.digest)=(i.receipt,i.digest))) THEN RETURN 'unindexed'; END IF;
    IF EXISTS(SELECT FROM meton_inbox.refund_terminal_facts f WHERE (f.channel,f.cash_environment,f.merchant,f.outcome->>'refundOrder')=
        (s->>'channel',s->>'cashEnvironment',s->>'merchant',k->>'refundOrder')) THEN RETURN 'observed'; END IF;
    -- 同一原付款可以分次退。未能绑定到本系统已知原退款的额外渠道退款，不能直接和本笔一起发送。
    IF EXISTS(SELECT FROM meton_inbox.refund_terminal_facts f WHERE f.original=original_trade AND NOT EXISTS(
        SELECT FROM meton_inbox.refund_wire_bindings b WHERE (b.channel,b.cash_environment,b.merchant,b.refund_number)=
            (s->>'channel',s->>'cashEnvironment',s->>'merchant',f.outcome->>'refundOrder'))) THEN RETURN 'foreign_attempt'; END IF;
    RETURN 'clear';
END $$;
CREATE FUNCTION meton_inbox.original_refund_query_result(ref uuid) RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT CASE WHEN count(DISTINCT economic_hash)>1 OR count(DISTINCT provider_state) FILTER(WHERE provider_state<>'PROCESSING')>1
        OR coalesce(bool_or(method='GET' AND provider_state='ABNORMAL'),false) THEN 'review' WHEN coalesce(bool_or(method='GET' AND provider_state IN ('SUCCESS','CLOSED')),false)
        THEN 'evidence' ELSE 'pending' END FROM meton_inbox.refund_wire_observations WHERE refund=ref
$$;
CREATE FUNCTION meton_inbox.bind_original_refund_dispatch(s jsonb,t jsonb,permit text,e jsonb,wire_mac text,wanted text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_original_wire_sender(s);
    ref uuid:=(t->>'refund')::uuid; b meton_inbox.refund_wire_bindings; gate jsonb; d meton_inbox.refund_gate_decisions; risk text; allow_claim boolean;
BEGIN
    IF wanted IS NULL OR wanted NOT IN ('claim','query') OR ((s->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE
        OR e->>'format' IS DISTINCT FROM '1' OR e->'target' IS DISTINCT FROM t
        OR (e->'scope')-ARRAY['merchant','app','channel','cashEnvironment'] IS DISTINCT FROM s-'validUntil'
        OR (e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',e#>>'{scope,app}') IS DISTINCT FROM
            ('wechatpay','isolated',e#>>'{cash,merchant}',e#>>'{cash,app}') OR
        (t->>'outRefundNo',t->>'fen') IS DISTINCT FROM (e#>>'{cash,refundOrder}',e#>>'{cash,refundFen}') OR
        wire_mac IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.dispatch.v1',wanted,s,e)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified original refund transport binding' USING ERRCODE='42501'; END IF;
    IF (e->>'queryUntil')::timestamptz<=clock_timestamp() THEN RETURN jsonb_build_object('state','review'); END IF;
    risk:=meton_inbox.original_refund_wire_risk(e);
    IF risk='unindexed' THEN RETURN jsonb_build_object('state','pending'); END IF;
    allow_claim:=wanted='claim' AND risk='clear' AND (e->>'sendUntil')::timestamptz>clock_timestamp();
    INSERT INTO meton_inbox.refund_wire_bindings(refund,envelope,initial_mode,channel,cash_environment,merchant,refund_number)
        VALUES(ref,e,CASE WHEN allow_claim THEN 'claim' ELSE 'query' END,e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',e#>>'{cash,refundOrder}')
        ON CONFLICT DO NOTHING;
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    IF b.envelope IS DISTINCT FROM e THEN RETURN jsonb_build_object('state','review'); END IF;
    IF risk='foreign_attempt' THEN RETURN jsonb_build_object('state','review'); END IF;
    SELECT * INTO d FROM meton_inbox.refund_gate_decisions WHERE refund=ref;
    IF d.refund IS NOT NULL OR allow_claim AND b.initial_mode='claim' THEN
        gate:=meton_inbox.decide_original_refund(s,t,permit,'claimed');
    END IF;
    RETURN jsonb_build_object('state',CASE meton_inbox.original_refund_query_result(ref) WHEN 'review' THEN 'review' WHEN 'evidence' THEN 'evidence'
        ELSE 'ready' END,'gate',gate);
END $$;

CREATE FUNCTION meton_inbox.start_bound_refund_io(s jsonb,ref uuid,ticket_id uuid,send_secret text,source_permit text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_original_wire_sender(s); b meton_inbox.refund_wire_bindings;
BEGIN
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref AND recorded_xid<>pg_current_xact_id();
    IF b.refund IS NULL OR source_permit IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.io.v1',s,b.envelope,ticket_id)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'source dispatch not durable' USING ERRCODE='42501'; END IF;
    IF b.initial_mode<>'claim' OR (b.envelope->>'sendUntil')::timestamptz<=clock_timestamp() OR meton_inbox.original_refund_wire_risk(b.envelope)<>'clear' THEN RETURN NULL; END IF;
    RETURN meton_inbox.start_original_refund_transport(s,ref,ticket_id,send_secret);
END $$;

CREATE FUNCTION meton_inbox.hold_bound_refund_io(s jsonb,ref uuid,ticket_id uuid,io_secret text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b meton_inbox.refund_wire_bindings;
BEGIN
    PERFORM meton_inbox.require_original_wire_sender(s);
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    IF b.refund IS NULL OR (b.envelope->>'sendUntil')::timestamptz<=clock_timestamp() OR meton_inbox.original_refund_wire_risk(b.envelope)<>'clear' THEN RETURN false; END IF;
    RETURN meton_inbox.hold_original_refund_transport(s,ref,ticket_id,io_secret);
END $$;

-- 工作进程消失后，只有原许可已到期、数据库传输锁已排空，才可永久退役。任何已登记的出站可能性都保留。
CREATE FUNCTION meton_inbox.retire_elapsed_refund_sender(s jsonb,ref uuid,ticket_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_gate_decisions:=meton_inbox.lock_refund_sender(s,ref,ticket_id);
BEGIN
    IF (d.issued_scope->>'validUntil')::timestamptz>clock_timestamp() THEN RETURN false; END IF;
    INSERT INTO meton_inbox.refund_sender_retirements(refund,ticket,may_have_sent)
        VALUES(ref,ticket_id,EXISTS(SELECT FROM meton_inbox.refund_transport_starts WHERE refund=ref)) ON CONFLICT DO NOTHING;
    RETURN true;
END $$;

CREATE FUNCTION meton_inbox.record_original_refund_transport(s jsonb,ref uuid,verb text,provider_status text,wire_hash bytea,proof_hash bytea,meaning jsonb,recovery_ref text,ciphertext bytea)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b meton_inbox.refund_wire_bindings; identity_hash bytea:=sha256(convert_to(meaning::text,'UTF8')); k jsonb;
BEGIN
    PERFORM meton_inbox.require_original_wire_sender(s);
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    k:=b.envelope->'cash';
    IF b.refund IS NULL OR (b.envelope->'scope')-ARRAY['channel','cashEnvironment','merchant','app'] IS DISTINCT FROM s-'validUntil' OR
        (meaning->>'order',meaning->>'transaction',meaning->>'refundOrder',meaning->>'total',meaning->>'refundFen') IS DISTINCT FROM
            (k->>'order',k->>'transaction',k->>'refundOrder',k->>'total',k->>'refundFen') OR
        (meaning->>'refundID'~'^[A-Za-z0-9_.:-]{1,64}$' AND (meaning->>'payerTotal')::bigint BETWEEN 0 AND (k->>'total')::bigint AND
            (meaning->>'payerRefund')::bigint BETWEEN 0 AND least((k->>'refundFen')::bigint,(meaning->>'payerTotal')::bigint) AND
            (coalesce((k->>'payerTotalUnrecorded')::boolean,false) OR meaning->>'payerTotal'=k->>'payerTotal')) IS NOT TRUE OR
        verb IS NULL OR verb NOT IN ('POST','GET') OR provider_status IS NULL OR provider_status NOT IN ('PROCESSING','SUCCESS','ABNORMAL','CLOSED')
        OR verb='POST' AND NOT EXISTS(SELECT FROM meton_inbox.refund_transport_uses WHERE refund=ref) THEN
        RAISE EXCEPTION 'original refund proof has no matching transport' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(b.envelope->'scope',b.envelope#>>'{cash,order}',b.envelope#>>'{cash,transaction}');
    INSERT INTO meton_inbox.refund_wire_observations(refund,method,provider_state,receipt_hash,basis_hash,fields,economic_hash,key_ref,sealed)
        VALUES(ref,verb,provider_status,wire_hash,proof_hash,meaning,identity_hash,recovery_ref,ciphertext) ON CONFLICT DO NOTHING;
    IF NOT EXISTS(SELECT FROM meton_inbox.refund_wire_observations v WHERE (v.refund,v.method,v.receipt_hash,v.basis_hash,v.economic_hash,v.provider_state)=
        (ref,verb,wire_hash,proof_hash,identity_hash,provider_status)) THEN RAISE EXCEPTION 'original refund receipt conflicts' USING ERRCODE='23505'; END IF;
    RETURN meton_inbox.original_refund_query_result(ref);
END $$;
-- 后到的关闭回调不得越过已归档的不同退款号、金额、成功或异常状态。处理中不能覆盖确定终态。
DO $review$ DECLARE body text:=pg_get_functiondef('meton_inbox.original_refund_failure(jsonb,uuid,bytea,uuid)'::regprocedure);
    anchor text:='terminal:=jsonb_build_object('; BEGIN
    IF cardinality(string_to_array(body,anchor))<>2 THEN RAISE EXCEPTION 'original signed failure check changed'; END IF;
    EXECUTE replace(body,anchor,$guard$IF EXISTS(SELECT FROM meton_inbox.refund_wire_observations x WHERE x.refund=ref AND
        (x.provider_state IN ('SUCCESS','ABNORMAL') OR (x.fields->>'refundID',x.fields->>'payerRefund',x.fields->>'payerTotal',x.fields->>'refundFen') IS DISTINCT FROM
            (n->>'refundID',n->>'payerRefund',n->>'payerTotal',n->>'refundFen'))) THEN RETURN jsonb_build_object('state','review'); END IF;
    $guard$||anchor);
END $review$;
CREATE FUNCTION meton_inbox.refund_dispatch_ready(route jsonb) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_inbox.refund_gate_authorities a JOIN meton_inbox.writers w
        ON (w.deployment,w.source_name,w.generation,w.source_system)=(a.deployment,a.source,a.epoch,a.source_system)
        WHERE (a.deployment,a.source,a.epoch,a.sender,a.source_system)=(route->>'deployment',route->>'source',(route->>'epoch')::bigint,session_user,route->>'sourceSystem')
        AND (w.channel,w.cash_environment,w.merchant,w.app)=(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
        AND a.source_system<>meton_inbox.system_id() AND route->>'inboxSystem'=meton_inbox.system_id())
$$;
REVOKE ALL ON FUNCTION meton_inbox.refund_dispatch_ready(jsonb),meton_inbox.require_original_wire_sender(jsonb),meton_inbox.original_refund_wire_risk(jsonb),
    meton_inbox.original_refund_query_result(uuid),
    meton_inbox.bind_original_refund_dispatch(jsonb,jsonb,text,jsonb,text,text),meton_inbox.start_bound_refund_io(jsonb,uuid,uuid,text,text),
    meton_inbox.hold_bound_refund_io(jsonb,uuid,uuid,text),meton_inbox.retire_elapsed_refund_sender(jsonb,uuid,uuid),
    meton_inbox.record_original_refund_transport(jsonb,uuid,text,text,bytea,bytea,jsonb,text,bytea) FROM PUBLIC;
