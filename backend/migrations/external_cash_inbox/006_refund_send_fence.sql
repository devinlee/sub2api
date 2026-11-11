-- 使用 PostgreSQL 自带的 pgcrypto。已安装在其他 schema 时绑定该扩展真实拥有的 HMAC 函数。
DO $crypto$
DECLARE ns name; routine oid;
BEGIN
    IF NOT EXISTS(SELECT FROM pg_extension WHERE extname='pgcrypto') THEN
        CREATE SCHEMA meton_refund_crypto;
        CREATE EXTENSION pgcrypto WITH SCHEMA meton_refund_crypto;
    END IF;
    SELECT n.nspname INTO STRICT ns FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='pgcrypto';
    routine:=to_regprocedure(format('%I.hmac(bytea,bytea,text)',ns));
    IF NOT EXISTS(SELECT FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE e.extname='pgcrypto'
        AND d.classid='pg_proc'::regclass AND d.objid=routine AND d.refclassid='pg_extension'::regclass AND d.deptype='e') THEN
        RAISE EXCEPTION 'refund receipt HMAC unavailable'; END IF;
    EXECUTE format('CREATE FUNCTION meton_inbox.refund_seal_mac(bytea,bytea) RETURNS bytea LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp AS %L',
        format('SELECT %I.hmac($1,$2,''sha256'')',ns));
END $crypto$;
REVOKE ALL ON FUNCTION meton_inbox.refund_seal_mac(bytea,bytea) FROM PUBLIC;

-- 原订单恢复范围外的这一行决定是否还能够发出原退款。授权代次和签名版本不组成退款唯一键。
CREATE TABLE meton_inbox.refund_gate_authorities(
    deployment text NOT NULL, source text NOT NULL, epoch bigint NOT NULL CHECK(epoch>0),
    source_system text NOT NULL, key_ref uuid NOT NULL, seal_key bytea NOT NULL CHECK(octet_length(seal_key)=32),
    stopper name NOT NULL, sender name NOT NULL CHECK(sender<>stopper), PRIMARY KEY(deployment,source)
);
CREATE TABLE meton_inbox.refund_gate_decisions(
    refund uuid PRIMARY KEY, target jsonb NOT NULL, choice text NOT NULL CHECK(choice IN ('stopped','claimed')),
    ticket uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(), created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE FUNCTION meton_inbox.keep_refund_gate() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN RAISE EXCEPTION 'original refund gate is immutable' USING ERRCODE='55000'; END $$;
CREATE TRIGGER immutable_refund_gate BEFORE UPDATE OR DELETE ON meton_inbox.refund_gate_decisions
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.refund_gate_decisions ENABLE ALWAYS TRIGGER immutable_refund_gate;
REVOKE ALL ON meton_inbox.refund_gate_authorities,meton_inbox.refund_gate_decisions FROM PUBLIC;

CREATE FUNCTION meton_inbox.decide_original_refund(context jsonb,target jsonb,origin_proof text,want text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities; d meton_inbox.refund_gate_decisions; ref uuid:=(target->>'refund')::uuid;
    acquired boolean; facts jsonb; archive text:=meton_inbox.system_id();
BEGIN
    IF current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply')
        OR current_setting('transaction_isolation')<>'read committed' OR current_setting('session_replication_role')<>'origin' OR pg_is_in_recovery() THEN
        RAISE EXCEPTION 'durable refund archive unavailable' USING ERRCODE='55000'; END IF;
    SELECT * INTO a FROM meton_inbox.refund_gate_authorities WHERE (deployment,source,epoch,source_system,key_ref)=
        (context->>'deployment',context->>'source',(context->>'epoch')::bigint,context->>'sourceSystem',(context->>'keyRef')::uuid)
        AND source_system<>archive AND archive=context->>'inboxSystem' FOR SHARE;
    IF NOT FOUND OR want NOT IN ('stopped','claimed') OR want IS NULL OR
        session_user IS DISTINCT FROM (CASE WHEN want='stopped' THEN a.stopper ELSE a.sender END) OR pg_has_role(session_user,current_user,'MEMBER') OR
        has_schema_privilege(session_user,'meton_inbox','CREATE') OR EXISTS(SELECT FROM pg_class t WHERE t.relnamespace='meton_inbox'::regnamespace
        AND t.relkind IN ('r','p') AND (has_table_privilege(session_user,t.oid,'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER') OR has_any_column_privilege(session_user,t.oid,'INSERT,UPDATE')))
        OR has_column_privilege(session_user,'meton_inbox.refund_gate_authorities','seal_key','SELECT') THEN
        RAISE EXCEPTION 'refund archive authority unavailable' USING ERRCODE='42501'; END IF;
    IF (jsonb_typeof(target)='object' AND octet_length(target::text)<=2048 AND ref<>'00000000-0000-0000-0000-000000000000'::uuid
        AND (target->>'intent')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid AND (target->>'marker')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid
        AND (target->>'order')::bigint>0 AND (target->>'fen')::bigint>0 AND target->>'outRefundNo'='R'||replace(ref::text,'-','')
        AND target->>'paramsHash' ~ '^[0-9a-f]{64}$' AND num_nonnulls(target->>'part',target->>'cutoff')=1
        AND target->>'basis' IN ('purchased_source','unposted_cash')) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid original refund' USING ERRCODE='22023'; END IF;
    IF (context->>'validUntil')::timestamptz IS NULL OR (context->>'validUntil')::timestamptz<=clock_timestamp()
        OR (context->>'validUntil')::timestamptz>clock_timestamp()+interval '30 seconds' OR
        origin_proof IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.origin.v1',want,context,target)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'refund origin permit invalid' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.refund_gate_decisions(refund,target,choice) VALUES(ref,target,want) ON CONFLICT(refund) DO NOTHING;
    acquired:=FOUND;
    SELECT * INTO STRICT d FROM meton_inbox.refund_gate_decisions WHERE refund=ref;
    IF d.target IS DISTINCT FROM target THEN RAISE EXCEPTION 'refund original differs' USING ERRCODE='23505'; END IF;
    IF (context->>'validUntil')::timestamptz<=clock_timestamp() THEN RAISE EXCEPTION 'refund permit expired before commit' USING ERRCODE='55000'; END IF;
    facts:=jsonb_build_object('format',1,'scope',context,'target',d.target,'choice',d.choice,'ticket',d.ticket);
    -- granted 只在第一次发送申请成功提交后使用。补查、重试、或提交应答丢失均不再次给出发送许可。
    RETURN jsonb_build_object('granted',acquired AND want='claimed','facts',facts,'mac',encode(meton_inbox.refund_seal_mac(convert_to(facts::text,'UTF8'),a.seal_key),'hex'));
END $$;
CREATE FUNCTION meton_inbox.stop_original_refund(jsonb,jsonb,text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_inbox.decide_original_refund($1,$2,$3,'stopped') $$;
CREATE FUNCTION meton_inbox.claim_original_refund(jsonb,jsonb,text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp
AS $$ SELECT meton_inbox.decide_original_refund($1,$2,$3,'claimed') $$;
REVOKE ALL ON FUNCTION meton_inbox.keep_refund_gate(),meton_inbox.decide_original_refund(jsonb,jsonb,text,text),
    meton_inbox.stop_original_refund(jsonb,jsonb,text),meton_inbox.claim_original_refund(jsonb,jsonb,text) FROM PUBLIC;
