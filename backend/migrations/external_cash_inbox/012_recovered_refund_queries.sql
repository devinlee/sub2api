-- 新签名版本只核对归档中业已固定的经济身份。原退款号、原付款、归属人与独立库的查询截止均不得变化。
CREATE TABLE meton_inbox.refund_wire_workers(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,key_ref uuid NOT NULL,worker_role name NOT NULL,
    PRIMARY KEY(deployment,source,epoch,key_ref),UNIQUE(deployment,source,worker_role)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.refund_wire_workers FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.refund_wire_workers ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_inbox.refund_wire_workers FROM PUBLIC;
DO $workers$ DECLARE body text; k text; BEGIN
    body:=pg_get_functiondef('meton_inbox.require_original_wire_sender(jsonb)'::regprocedure);
    k:='IF a.key_ref IS NULL OR';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original refund sender check changed'; END IF;
    EXECUTE replace(body,k,'IF NOT EXISTS(SELECT FROM meton_inbox.refund_wire_workers w WHERE (w.deployment,w.source,w.epoch,w.key_ref,w.worker_role)=
        (a.deployment,a.source,a.epoch,a.key_ref,session_user)) OR a.key_ref IS NULL OR');
    body:=pg_get_functiondef('meton_inbox.refund_dispatch_ready(jsonb)'::regprocedure);k:='WHERE (a.deployment';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'archive sender readiness changed'; END IF;
    EXECUTE replace(body,k,'WHERE EXISTS(SELECT FROM meton_inbox.refund_wire_workers p WHERE (p.deployment,p.source,p.epoch,p.key_ref,p.worker_role)=
        (a.deployment,a.source,a.epoch,a.key_ref,session_user)) AND (a.deployment');
    body:=pg_get_functiondef('meton_inbox.lock_refund_sender(jsonb,uuid,uuid)'::regprocedure);
    k:='PERFORM pg_advisory_xact_lock(';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original transport guard changed'; END IF;
    EXECUTE replace(body,k,'PERFORM meton_inbox.require_original_wire_sender(scope); '||k);
    body:=pg_get_functiondef('meton_inbox.decide_original_refund(jsonb,jsonb,text,text)'::regprocedure);
    k:='IF want=''claimed'' THEN volatile_secret:=';
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original sender grant changed'; END IF;
    EXECUTE replace(body,k,'IF want=''claimed'' THEN PERFORM meton_inbox.require_original_wire_sender(context); volatile_secret:=');
END $workers$;
CREATE FUNCTION meton_inbox.recovered_refund_capability(s jsonb,e jsonb) RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_original_wire_sender(s);
BEGIN
    RETURN encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.recovered.get.v1',s,e)::text,'UTF8'),a.seal_key),'hex');
END $$;
CREATE FUNCTION meton_inbox.authorize_recovered_refund_lookup(s jsonb,request jsonb,permit text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_original_wire_sender(s);b meton_inbox.refund_wire_bindings; old_scope jsonb;
    ref uuid:=(request#>>'{target,refund}')::uuid; deadline timestamptz; state text; capability text;
BEGIN
    IF permit IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.recovered.lookup.v1',s,request)::text,'UTF8'),a.seal_key),'hex')
        OR ((s->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        request->>'originalInbox' IS DISTINCT FROM meton_inbox.system_id() THEN RAISE EXCEPTION 'invalid recovered refund lookup' USING ERRCODE='42501'; END IF;
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref AND recorded_xid<>pg_current_xact_id();
    old_scope:=b.envelope->'scope';
    IF b.refund IS NULL OR (b.envelope->'target',b.envelope->'cash',b.envelope->'paidAt',b.envelope->'acceptedAt') IS DISTINCT FROM
        (request->'target',request->'cash',request->'paidAt',request->'acceptedAt') OR
        (old_scope->>'deployment',old_scope->>'source',old_scope->>'epoch',old_scope->>'sourceSystem',old_scope->>'inboxSystem',
            b.channel,b.cash_environment,b.merchant,old_scope->>'app',b.refund_number) IS DISTINCT FROM
        (s->>'deployment',s->>'source',request->>'originalEpoch',request->>'originalSystem',request->>'originalInbox',
            request->>'channel',request->>'cashEnvironment',request->>'merchant',request->>'app',request#>>'{cash,refundOrder}') THEN
        RETURN jsonb_build_object('state','review'); END IF;
    deadline:=least((b.envelope->>'queryUntil')::timestamptz,(request->>'queryUntil')::timestamptz);
    IF deadline<=clock_timestamp() THEN RETURN jsonb_build_object('state','review'); END IF;
    PERFORM meton_inbox.lock_original_cash(old_scope,b.envelope#>>'{cash,order}',b.envelope#>>'{cash,transaction}');
    state:=meton_inbox.original_refund_query_result(ref);
    IF state IN ('review','evidence') THEN RETURN jsonb_build_object('state',state); END IF;
    capability:=meton_inbox.recovered_refund_capability(s,b.envelope);
    RETURN jsonb_build_object('state','ready','envelope',b.envelope,'queryUntil',deadline,'lookup',capability);
END $$;

-- 复用原验签应答的存储流程；遇到代次或密钥变更，只有绑定原归档的短期只读凭据可追加 GET 证据。
DO $append$
DECLARE old text:=pg_get_functiondef('meton_inbox.record_original_refund_transport(jsonb,uuid,text,text,bytea,bytea,jsonb,text,bytea)'::regprocedure);
    body text; anchor text:='IF b.refund IS NULL OR (b.envelope->''scope'')-ARRAY[''channel'',''cashEnvironment'',''merchant'',''app''] IS DISTINCT FROM s-''validUntil'' OR';
BEGIN
    IF cardinality(string_to_array(old,anchor))<>2 OR cardinality(string_to_array(old,'ciphertext bytea)'))<>2 THEN
        RAISE EXCEPTION 'signed refund observation guard changed'; END IF;
    body:=replace(old,'meton_inbox.record_original_refund_transport(','meton_inbox.append_bound_refund_observation(');
    body:=replace(body,'ciphertext bytea)','ciphertext bytea,lookup text)');
    body:=replace(body,anchor,$purpose$IF b.refund IS NULL OR (
        (b.envelope->'scope')-ARRAY['channel','cashEnvironment','merchant','app'] IS DISTINCT FROM s-'validUntil' AND
        (verb='GET' AND (s->>'validUntil')::timestamptz>=clock_timestamp()
            AND lookup=meton_inbox.recovered_refund_capability(s,b.envelope)) IS NOT TRUE) OR$purpose$);
    EXECUTE body;
END $append$;
CREATE OR REPLACE FUNCTION meton_inbox.record_original_refund_transport(s jsonb,ref uuid,verb text,provider_status text,wire_hash bytea,proof_hash bytea,meaning jsonb,recovery_ref text,ciphertext bytea)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_inbox.append_bound_refund_observation(s,ref,verb,provider_status,wire_hash,proof_hash,meaning,recovery_ref,ciphertext,NULL)
$$;
CREATE FUNCTION meton_inbox.record_recovered_refund_get(s jsonb,ref uuid,provider_status text,wire_hash bytea,proof_hash bytea,meaning jsonb,recovery_ref text,ciphertext bytea,lookup text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b meton_inbox.refund_wire_bindings;
BEGIN
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    IF b.refund IS NULL OR least((s->>'validUntil')::timestamptz,(b.envelope->>'queryUntil')::timestamptz)<=clock_timestamp()
        OR lookup IS DISTINCT FROM meton_inbox.recovered_refund_capability(s,b.envelope) THEN
        RAISE EXCEPTION 'expired or mismatched recovered lookup' USING ERRCODE='42501'; END IF;
    RETURN meton_inbox.append_bound_refund_observation(s,ref,'GET',provider_status,wire_hash,proof_hash,meaning,recovery_ref,ciphertext,lookup);
END $$;
REVOKE ALL ON FUNCTION meton_inbox.authorize_recovered_refund_lookup(jsonb,jsonb,text),
    meton_inbox.recovered_refund_capability(jsonb,jsonb),
    meton_inbox.append_bound_refund_observation(jsonb,uuid,text,text,bytea,bytea,jsonb,text,bytea,text),
    meton_inbox.record_recovered_refund_get(jsonb,uuid,text,bytea,bytea,jsonb,text,bytea,text) FROM PUBLIC;
