-- 只有首次认领者得到运行时秘密。状态读取、重放与新进程均无法取得另一份出站许可。
ALTER TABLE meton_inbox.refund_gate_decisions ADD COLUMN sender_hash bytea CHECK(sender_hash IS NULL OR choice='claimed' AND octet_length(sender_hash)=32),
    ADD COLUMN issued_scope jsonb, ADD COLUMN decision_xid xid8 NOT NULL DEFAULT pg_current_xact_id(), ADD UNIQUE(refund,ticket);
CREATE TABLE meton_inbox.refund_transport_starts(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_gate_decisions, ticket uuid NOT NULL UNIQUE,
    io_hash bytea NOT NULL CHECK(octet_length(io_hash)=32), start_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    valid_until timestamptz NOT NULL CHECK(isfinite(valid_until)), FOREIGN KEY(refund,ticket) REFERENCES meton_inbox.refund_gate_decisions(refund,ticket)
);
CREATE TABLE meton_inbox.refund_transport_uses(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_transport_starts,ticket uuid NOT NULL,
    FOREIGN KEY(refund,ticket) REFERENCES meton_inbox.refund_gate_decisions(refund,ticket)
);
CREATE TABLE meton_inbox.refund_sender_retirements(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_gate_decisions,ticket uuid NOT NULL UNIQUE,may_have_sent boolean NOT NULL,
    retired_at timestamptz NOT NULL DEFAULT clock_timestamp(), retired_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    FOREIGN KEY(refund,ticket) REFERENCES meton_inbox.refund_gate_decisions(refund,ticket)
);
CREATE TRIGGER immutable_refund_start BEFORE UPDATE OR DELETE ON meton_inbox.refund_transport_starts
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
CREATE TRIGGER immutable_sender_retirement BEFORE UPDATE OR DELETE ON meton_inbox.refund_sender_retirements
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
CREATE TRIGGER immutable_refund_use BEFORE UPDATE OR DELETE ON meton_inbox.refund_transport_uses
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.refund_transport_starts ENABLE ALWAYS TRIGGER immutable_refund_start;
ALTER TABLE meton_inbox.refund_sender_retirements ENABLE ALWAYS TRIGGER immutable_sender_retirement;
ALTER TABLE meton_inbox.refund_transport_uses ENABLE ALWAYS TRIGGER immutable_refund_use;
REVOKE ALL ON meton_inbox.refund_transport_starts,meton_inbox.refund_sender_retirements,meton_inbox.refund_transport_uses FROM PUBLIC;

DO $upgrade$
DECLARE src text:=pg_get_functiondef('meton_inbox.decide_original_refund(jsonb,jsonb,text,text)'::regprocedure);
    init constant text:='acquired boolean; facts jsonb;';
    insert_at constant text:='INSERT INTO meton_inbox.refund_gate_decisions(refund,target,choice) VALUES(ref,target,want)';
    facts_at constant text:='''choice'',d.choice';
    return_at constant text:='RETURN jsonb_build_object(''granted'',acquired';
    mac_at constant text:='encode(meton_inbox.refund_seal_mac(convert_to(facts::text,''UTF8''),a.seal_key),''hex'')';
BEGIN
    IF cardinality(string_to_array(src,init))<>2 OR cardinality(string_to_array(src,insert_at))<>2 OR
        cardinality(string_to_array(src,facts_at))<>2 OR cardinality(string_to_array(src,return_at))<>2 OR cardinality(string_to_array(src,mac_at))<>2
        OR cardinality(string_to_array(src,'facts:=jsonb_build_object('))<>2 THEN
        RAISE EXCEPTION 'original refund decision changed'; END IF;
    src:=replace(src,init,'volatile_secret bytea; observed text; '||init);
    src:=replace(src,insert_at,$grant$IF want='claimed' THEN volatile_secret:=uuid_send(gen_random_uuid())||uuid_send(gen_random_uuid()); END IF;
    INSERT INTO meton_inbox.refund_gate_decisions(refund,target,choice,sender_hash,issued_scope) VALUES(ref,target,want,sha256(volatile_secret),context)$grant$);
    src:=replace(src,'facts:=jsonb_build_object(',$observe$SELECT CASE WHEN NOT may_have_sent THEN 'unsent' ELSE d.choice END INTO observed
        FROM meton_inbox.refund_sender_retirements WHERE refund=ref AND ticket=d.ticket AND retired_xid<>pg_current_xact_id();
    facts:=jsonb_build_object($observe$);
    src:=replace(src,facts_at,'''choice'',coalesce(observed,d.choice)');
    src:=replace(src,mac_at,'CASE WHEN d.decision_xid<>pg_current_xact_id() THEN '||mac_at||' END');
    EXECUTE replace(src,return_at,$grant$RETURN (CASE WHEN acquired AND want='claimed' THEN jsonb_build_object('sendSecret',encode(volatile_secret,'hex'))
        ELSE '{}'::jsonb END)||jsonb_build_object('granted',acquired$grant$);
END $upgrade$;

-- 发送方每次重新核对当前写者。锁跨越实际传输期间；退还发送权与开始传输在同一把锁上互斥。
CREATE FUNCTION meton_inbox.lock_refund_sender(scope jsonb,ref uuid,original_ticket uuid) RETURNS meton_inbox.refund_gate_decisions
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities; d meton_inbox.refund_gate_decisions;
BEGIN
    SELECT * INTO a FROM meton_inbox.refund_gate_authorities WHERE (deployment,source,epoch,source_system,key_ref,sender)=
        (scope->>'deployment',scope->>'source',(scope->>'epoch')::bigint,scope->>'sourceSystem',(scope->>'keyRef')::uuid,session_user) FOR SHARE;
    IF NOT FOUND OR a.source_system=meton_inbox.system_id() OR scope->>'inboxSystem' IS DISTINCT FROM meton_inbox.system_id()
        OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply')
        OR current_setting('transaction_isolation')<>'read committed' OR current_setting('session_replication_role')<>'origin' OR pg_is_in_recovery()
        OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_inbox','CREATE') OR
        EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
            (has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE') OR has_table_privilege(session_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'original refund sender unavailable' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.refund.transport.v1/'||ref::text,0));
    SELECT * INTO d FROM meton_inbox.refund_gate_decisions WHERE (refund,ticket,choice)=(ref,original_ticket,'claimed');
    IF NOT FOUND OR d.sender_hash IS NULL OR d.issued_scope-'validUntil' IS DISTINCT FROM scope-'validUntil' OR d.decision_xid=pg_current_xact_id() THEN
        RAISE EXCEPTION 'original sender has no committed grant in this generation' USING ERRCODE='42501'; END IF;
    RETURN d;
END $$;

-- 先提交「可能出站」记录。只有首次成功应答交付内存中的 I/O 秘密，提交未知或重领只查原退款。
CREATE FUNCTION meton_inbox.start_original_refund_transport(scope jsonb,ref uuid,original_ticket uuid,send_secret text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_gate_decisions:=meton_inbox.lock_refund_sender(scope,ref,original_ticket);
    until_at timestamptz:=least((d.issued_scope->>'validUntil')::timestamptz,(scope->>'validUntil')::timestamptz); io_secret bytea;
BEGIN
    IF send_secret IS NULL OR send_secret !~ '^[0-9a-f]{64}$' OR sha256(decode(send_secret,'hex'))<>d.sender_hash THEN
        RAISE EXCEPTION 'original sender proof invalid' USING ERRCODE='42501'; END IF;
    IF until_at IS NULL OR until_at<=clock_timestamp() OR until_at>clock_timestamp()+interval '30 seconds'
        OR EXISTS(SELECT FROM meton_inbox.refund_sender_retirements WHERE refund=ref) THEN RETURN NULL; END IF;
    io_secret:=uuid_send(gen_random_uuid())||uuid_send(gen_random_uuid());
    INSERT INTO meton_inbox.refund_transport_starts(refund,ticket,io_hash,valid_until) VALUES(ref,original_ticket,sha256(io_secret),until_at) ON CONFLICT DO NOTHING;
    RETURN CASE WHEN FOUND THEN encode(io_secret,'hex') END;
END $$;

CREATE FUNCTION meton_inbox.hold_original_refund_transport(scope jsonb,ref uuid,original_ticket uuid,io_secret text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_refund_sender(scope,ref,original_ticket);
    IF io_secret IS NULL OR io_secret !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid transport proof' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.refund_transport_uses(refund,ticket)
        SELECT ref,original_ticket FROM meton_inbox.refund_transport_starts r WHERE (r.refund,r.ticket,r.io_hash)=(ref,original_ticket,sha256(decode(io_secret,'hex')))
        AND r.start_xid<>pg_current_xact_id() AND r.valid_until>clock_timestamp()
        AND NOT EXISTS(SELECT FROM meton_inbox.refund_sender_retirements WHERE refund=ref) ON CONFLICT DO NOTHING;
    RETURN FOUND;
END $$;

CREATE FUNCTION meton_inbox.retire_original_refund_sender(scope jsonb,ref uuid,original_ticket uuid,send_secret text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_gate_decisions:=meton_inbox.lock_refund_sender(scope,ref,original_ticket);
    retired meton_inbox.refund_sender_retirements; facts jsonb; secret bytea;
BEGIN
    IF send_secret IS NULL OR send_secret !~ '^[0-9a-f]{64}$' OR sha256(decode(send_secret,'hex'))<>d.sender_hash THEN
        RAISE EXCEPTION 'invalid original surrender' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.refund_sender_retirements(refund,ticket,may_have_sent)
        VALUES(ref,original_ticket,EXISTS(SELECT FROM meton_inbox.refund_transport_starts WHERE refund=ref)) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT retired FROM meton_inbox.refund_sender_retirements WHERE refund=ref AND ticket=original_ticket;
    SELECT seal_key INTO STRICT secret FROM meton_inbox.refund_gate_authorities WHERE deployment=scope->>'deployment' AND source=scope->>'source';
    facts:=jsonb_build_object('format',1,'scope',scope,'target',d.target,'choice',CASE WHEN retired.may_have_sent THEN 'retired' ELSE 'unsent' END,'ticket',d.ticket);
    RETURN jsonb_build_object('facts',facts,'mac',CASE WHEN retired.retired_xid<>pg_current_xact_id()
        THEN encode(meton_inbox.refund_seal_mac(convert_to(facts::text,'UTF8'),secret),'hex') END);
END $$;
REVOKE ALL ON FUNCTION meton_inbox.lock_refund_sender(jsonb,uuid,uuid),
    meton_inbox.start_original_refund_transport(jsonb,uuid,uuid,text),meton_inbox.hold_original_refund_transport(jsonb,uuid,uuid,text),
    meton_inbox.retire_original_refund_sender(jsonb,uuid,uuid,text) FROM PUBLIC;

-- 第二次事务只接收已经提交的原行。缺行或截点外尚未恢复时返回未知，不能因此补建一项停止。
CREATE FUNCTION meton_inbox.read_original_refund_stop(context jsonb,p_target jsonb,origin_proof text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM FROM meton_inbox.refund_gate_decisions d WHERE (d.refund,d.target)=((p_target->>'refund')::uuid,p_target)
        AND d.decision_xid<>pg_current_xact_id() FOR SHARE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN meton_inbox.decide_original_refund(context,p_target,origin_proof,'stopped');
END $$;
REVOKE ALL ON FUNCTION meton_inbox.read_original_refund_stop(jsonb,jsonb,text) FROM PUBLIC;
