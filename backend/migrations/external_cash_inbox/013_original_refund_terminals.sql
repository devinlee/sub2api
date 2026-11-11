-- 渠道成功事实与原来源结清分开。每种实际报告的成功金额永久保留，只有原商户、交易、归属和金额全部吻合才能签发结清凭证。
CREATE TABLE meton_inbox.refund_resolution_roles(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,key_ref uuid NOT NULL,resolver name NOT NULL,
    PRIMARY KEY(deployment,source,epoch,key_ref),UNIQUE(deployment,source,resolver)
);
CREATE TABLE meton_inbox.refund_positive_cash(
    refund uuid NOT NULL REFERENCES meton_inbox.refund_wire_bindings, economic_hash bytea NOT NULL CHECK(octet_length(economic_hash)=32),
    fields jsonb NOT NULL,first_source text NOT NULL CHECK(first_source IN ('GET','callback')),observed_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    PRIMARY KEY(refund,economic_hash)
);
CREATE TABLE meton_inbox.refund_cash_disputes(
    refund uuid NOT NULL REFERENCES meton_inbox.refund_wire_bindings,digest bytea NOT NULL CHECK(octet_length(digest)=32),
    reason text NOT NULL,first_seen timestamptz NOT NULL DEFAULT clock_timestamp(),observed_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),PRIMARY KEY(refund,digest)
);
CREATE TABLE meton_inbox.refund_provider_owners(
    channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,provider_refund text NOT NULL,
    refund uuid NOT NULL REFERENCES meton_inbox.refund_wire_bindings,PRIMARY KEY(channel,cash_environment,merchant,provider_refund)
);
DO $p$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['refund_resolution_roles','refund_positive_cash','refund_cash_disputes','refund_provider_owners'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
    END LOOP;
END $p$;
REVOKE ALL ON meton_inbox.refund_resolution_roles,meton_inbox.refund_positive_cash,meton_inbox.refund_cash_disputes,meton_inbox.refund_provider_owners FROM PUBLIC;
CREATE INDEX refund_observed_provider_id ON meton_inbox.refund_wire_observations((fields->>'refundID'),refund);
CREATE INDEX refund_callback_provider_id ON meton_inbox.refund_terminal_facts(channel,cash_environment,merchant,(outcome->>'refundID'));

CREATE FUNCTION meton_inbox.require_refund_resolver(route jsonb) RETURNS meton_inbox.refund_gate_authorities
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities;
BEGIN
    SELECT g.* INTO a FROM meton_inbox.refund_gate_authorities g JOIN meton_inbox.refund_resolution_roles p USING(deployment,source,epoch,key_ref)
        JOIN meton_inbox.writers w ON (w.deployment,w.source_name,w.generation,w.source_system)=(g.deployment,g.source,g.epoch,g.source_system)
        WHERE (g.deployment,g.source,g.epoch,g.source_system,w.channel,w.cash_environment,w.merchant,w.app,p.resolver)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'sourceSystem',route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',session_user)
            AND g.sender<>p.resolver AND g.stopper<>p.resolver AND w.writer<>p.resolver FOR SHARE OF g,p,w;
    IF a.key_ref IS NULL OR route->>'inboxSystem' IS DISTINCT FROM meton_inbox.system_id() OR a.source_system=meton_inbox.system_id()
        OR pg_is_in_recovery() OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
        OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') OR current_setting('transaction_isolation')<>'read committed'
        OR current_setting('session_replication_role')<>'origin' OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_inbox','CREATE')
        OR EXISTS(SELECT FROM pg_roles r WHERE (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls) AND pg_has_role(session_user,r.oid,'MEMBER'))
        OR EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p')
            AND (has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE') OR has_table_privilege(session_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted cash resolution authority unavailable' USING ERRCODE='42501'; END IF;
    RETURN a;
END $$;

-- GET 和通知都来自此前实际验签的数据。POST 的状态只能如实保留、参与冲突核对，不产生成功现金证明。
CREATE FUNCTION meton_inbox.refund_resolution_samples(b meton_inbox.refund_wire_bindings)
RETURNS TABLE(transport text,reported text,fields jsonb,correct_owner boolean,conflicted boolean)
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT v.method,v.provider_state,v.fields,true,false FROM meton_inbox.refund_wire_observations v WHERE v.refund=b.refund
    UNION ALL
    SELECT 'callback',f.outcome->>'state',jsonb_build_object('order',f.outcome->'order','transaction',f.outcome->'transaction','refundOrder',f.outcome->'refundOrder',
        'refundID',f.outcome->'refundID','total',f.outcome->'total','payerTotal',f.outcome->'payerTotal','refundFen',f.outcome->'refundFen','payerRefund',f.outcome->'payerRefund'),
        (f.app,f.origin->>'sourceMarker',f.outcome->>'merchant',f.origin->>'channel',f.origin->>'cashEnvironment',f.origin->>'merchant',f.origin->>'app') IS NOT DISTINCT FROM
            (b.envelope#>>'{scope,app}',b.envelope#>>'{target,marker}',b.merchant,b.channel,b.cash_environment,b.merchant,b.envelope#>>'{scope,app}'),
        EXISTS(SELECT FROM meton_inbox.proofs p WHERE p.receipt=f.receipt AND NOT p.first_proof)
        FROM meton_inbox.refund_terminal_facts f WHERE (f.channel,f.cash_environment,f.merchant,f.outcome->>'refundOrder')=(b.channel,b.cash_environment,b.merchant,b.refund_number)
$$;

CREATE FUNCTION meton_inbox.original_refund_cash_result(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);b meton_inbox.refund_wire_bindings;s record;k jsonb;actual bytea;cash_key bytea;
    differing boolean:=false;positive boolean:=false;closed boolean:=false;abnormal boolean:=false;pending_index boolean;fresh boolean;sample_hash bytea;
    accepted meton_inbox.refund_positive_cash;scope jsonb;facts jsonb;positive_count integer;reason text;owner_ref uuid;
BEGIN
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    IF b.refund IS NULL OR (b.channel,b.cash_environment,b.merchant,b.envelope#>>'{scope,app}',b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}') IS DISTINCT FROM
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',route->>'deployment',route->>'source') THEN RETURN jsonb_build_object('state','unbound'); END IF;
    k:=b.envelope->'cash';cash_key:=meton_inbox.lock_original_cash(route,k->>'order',k->>'transaction');
    pending_index:=EXISTS(SELECT FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant)=(b.channel,b.cash_environment,b.merchant)) OR
        EXISTS(SELECT FROM meton_inbox.refund_evidence i WHERE i.original=cash_key AND NOT EXISTS(SELECT FROM meton_inbox.refund_terminal_facts f
            WHERE (f.receipt,f.digest)=(i.receipt,i.digest)));
    FOR s IN SELECT * FROM meton_inbox.refund_resolution_samples(b) ORDER BY fields->>'refundID',transport,fields::text,reported LOOP
        sample_hash:=sha256(convert_to(s.fields::text,'UTF8'));IF actual IS NULL THEN actual:=sample_hash; ELSIF actual<>sample_hash THEN differing:=true; END IF;
        differing:=differing OR NOT s.correct_owner OR s.conflicted OR
            (s.fields->>'order',s.fields->>'transaction',s.fields->>'refundOrder',s.fields->>'total',s.fields->>'refundFen') IS DISTINCT FROM
                (k->>'order',k->>'transaction',k->>'refundOrder',k->>'total',k->>'refundFen') OR
            ((s.fields->>'refundID'~'^[A-Za-z0-9_.:-]{1,64}$' AND (s.fields->>'payerTotal')::bigint BETWEEN 0 AND (k->>'total')::bigint AND
                (s.fields->>'payerRefund')::bigint BETWEEN 0 AND least((k->>'refundFen')::bigint,(s.fields->>'payerTotal')::bigint) AND
                (coalesce((k->>'payerTotalUnrecorded')::boolean,false) OR s.fields->>'payerTotal'=k->>'payerTotal')) IS NOT TRUE);
        IF s.reported='SUCCESS' THEN
            positive:=true;
            IF s.transport IN ('GET','callback') THEN
                INSERT INTO meton_inbox.refund_positive_cash(refund,economic_hash,fields,first_source) VALUES(ref,sample_hash,s.fields,s.transport) ON CONFLICT DO NOTHING;
                -- 两个不同原付款同时认领同一渠道退款号时，唯一索引使后来的事务见到先前的所有者。
                IF s.fields->>'refundID'~'^[A-Za-z0-9_.:-]{1,64}$' THEN
                    INSERT INTO meton_inbox.refund_provider_owners VALUES(b.channel,b.cash_environment,b.merchant,s.fields->>'refundID',ref) ON CONFLICT DO NOTHING;
                    SELECT p.refund INTO STRICT owner_ref FROM meton_inbox.refund_provider_owners p WHERE (p.channel,p.cash_environment,p.merchant,p.provider_refund)=
                        (b.channel,b.cash_environment,b.merchant,s.fields->>'refundID');
                    IF owner_ref<>ref THEN
                        differing:=true;
                        INSERT INTO meton_inbox.refund_cash_disputes(refund,digest,reason)
                            VALUES(owner_ref,sha256(convert_to(jsonb_build_array('shared_provider_refund',s.fields->>'refundID')::text,'UTF8')),'shared_provider_refund') ON CONFLICT DO NOTHING;
                    END IF;
                END IF;
            END IF;
        ELSIF s.reported='ABNORMAL' THEN abnormal:=true;
        ELSIF s.reported='CLOSED' THEN closed:=true; END IF;
        IF EXISTS(SELECT FROM meton_inbox.refund_terminal_facts f WHERE (f.channel,f.cash_environment,f.merchant,f.outcome->>'refundID')=
            (b.channel,b.cash_environment,b.merchant,s.fields->>'refundID') AND (f.original<>cash_key OR f.outcome->>'refundOrder'<>b.refund_number))
            OR EXISTS(SELECT FROM meton_inbox.refund_wire_observations x JOIN meton_inbox.refund_wire_bindings other ON other.refund=x.refund
            WHERE (other.channel,other.cash_environment,other.merchant,x.fields->>'refundID')=(b.channel,b.cash_environment,b.merchant,s.fields->>'refundID') AND x.refund<>ref) THEN
            differing:=true; END IF;
    END LOOP;
    SELECT count(*),coalesce(bool_or(observed_xid=pg_current_xact_id()),false) INTO positive_count,fresh FROM meton_inbox.refund_positive_cash p WHERE p.refund=ref;
    IF differing OR positive_count>1 THEN reason:='economic_conflict';
    ELSIF abnormal OR (positive AND closed) THEN reason:='channel_conflict';
    ELSIF positive_count>0 AND (EXISTS(SELECT FROM meton_inbox.refund_failed_proofs f WHERE f.refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.refund_gate_decisions d WHERE d.refund=ref AND d.choice='stopped') OR
        EXISTS(SELECT FROM meton_inbox.refund_sender_retirements t WHERE t.refund=ref AND NOT t.may_have_sent)) THEN reason:='previous_closed_proof';
    ELSIF positive_count>0 AND EXISTS(SELECT FROM meton_inbox.refund_terminal_facts f WHERE f.original=cash_key AND NOT EXISTS(
        SELECT FROM meton_inbox.refund_wire_bindings x WHERE (x.channel,x.cash_environment,x.merchant,x.refund_number)=(b.channel,b.cash_environment,b.merchant,f.outcome->>'refundOrder'))) THEN
        reason:='unassigned_refund_attempt'; END IF;
    IF reason IS NOT NULL THEN
        INSERT INTO meton_inbox.refund_cash_disputes(refund,digest,reason) VALUES(ref,sha256(convert_to(jsonb_build_array(reason,k)::text,'UTF8')),reason) ON CONFLICT DO NOTHING;
    END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    IF EXISTS(SELECT FROM meton_inbox.refund_cash_disputes WHERE refund=ref) THEN
        IF fresh OR EXISTS(SELECT FROM meton_inbox.refund_cash_disputes WHERE refund=ref AND observed_xid=pg_current_xact_id()) THEN
            RETURN jsonb_build_object('state','recorded'); END IF;
        facts:=jsonb_build_object('format',1,'scope',scope,'envelope',b.envelope,'confirmedCashVariants',positive_count,
            'reviewHash',(SELECT encode(sha256(convert_to(string_agg(encode(digest,'hex'),',' ORDER BY digest),'UTF8')),'hex')
                FROM meton_inbox.refund_cash_disputes WHERE refund=ref),'validUntil',clock_timestamp()+interval '25 seconds');
        RETURN jsonb_build_object('state','review','confirmedCashVariants',positive_count,'facts',facts,'mac',encode(meton_inbox.refund_seal_mac(
            convert_to(jsonb_build_array('meton.refund.disputed.v1',facts)::text,'UTF8'),a.seal_key),'hex')); END IF;
    IF pending_index THEN RETURN jsonb_build_object('state','pending'); END IF;
    IF positive_count=0 THEN RETURN jsonb_build_object('state',CASE WHEN closed THEN 'closed_observed' ELSE 'pending' END); END IF;
    IF fresh THEN RETURN jsonb_build_object('state','recorded'); END IF;
    SELECT * INTO STRICT accepted FROM meton_inbox.refund_positive_cash WHERE refund=ref;
    facts:=jsonb_build_object('format',1,'scope',scope,'envelope',b.envelope,'cash',accepted.fields,'economicHash',encode(accepted.economic_hash,'hex'),
        'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','success_proved','facts',facts,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.succeeded.v1',facts)::text,'UTF8'),a.seal_key),'hex'));
END $$;
DO $failure$
DECLARE body text:=pg_get_functiondef('meton_inbox.original_refund_failure(jsonb,uuid,bytea,uuid)'::regprocedure);k text:='terminal:=jsonb_build_object('; BEGIN
    IF cardinality(string_to_array(body,k))<>2 THEN RAISE EXCEPTION 'original failure evidence check changed'; END IF;
    EXECUTE replace(body,k,'IF EXISTS(SELECT FROM meton_inbox.refund_positive_cash p WHERE p.refund=ref) OR EXISTS(
        SELECT FROM meton_inbox.refund_cash_disputes d WHERE d.refund=ref) THEN RETURN jsonb_build_object(''state'',''review''); END IF; '||k);
END $failure$;
REVOKE ALL ON FUNCTION meton_inbox.require_refund_resolver(jsonb),meton_inbox.refund_resolution_samples(meton_inbox.refund_wire_bindings),meton_inbox.original_refund_cash_result(jsonb,uuid) FROM PUBLIC;
