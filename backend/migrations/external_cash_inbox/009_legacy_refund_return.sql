-- 历史发送者不持新退款票据。部署方登记原提供方的完整旧发送者清单；停用核验和资金复核采用不同身份。
CREATE TABLE meton_inbox.legacy_refund_deployments(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),provider_instance text NOT NULL,
    channel text NOT NULL CHECK(channel='wechatpay'),cash_environment text NOT NULL,merchant text NOT NULL,app text NOT NULL,
    inventory jsonb NOT NULL CHECK(jsonb_typeof(inventory)='object' AND inventory<>'{}'::jsonb AND octet_length(inventory::text)<=16384),
    inventory_evidence text NOT NULL CHECK(inventory_evidence~'^[0-9a-f]{64}$'),retirement_role name NOT NULL,review_role name NOT NULL CHECK(review_role<>retirement_role),
    PRIMARY KEY(deployment,source,epoch,provider_instance)
);
CREATE TABLE meton_inbox.legacy_sender_retirements(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,provider_instance text NOT NULL,actor text NOT NULL,
    credential_ref text NOT NULL,retirement_evidence text NOT NULL,drain_evidence text NOT NULL,attested_by name NOT NULL DEFAULT session_user,
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    PRIMARY KEY(deployment,source,epoch,provider_instance,actor),
    FOREIGN KEY(deployment,source,epoch,provider_instance) REFERENCES meton_inbox.legacy_refund_deployments
);
CREATE TABLE meton_inbox.legacy_refund_returns(
    marker uuid NOT NULL,native_order bigint NOT NULL,channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,refund_number text NOT NULL,
    scope jsonb NOT NULL,target jsonb NOT NULL,manifest jsonb NOT NULL,retirements jsonb NOT NULL,closure_proofs jsonb NOT NULL,
    reviewer name NOT NULL DEFAULT session_user,approved_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    PRIMARY KEY(marker,native_order), UNIQUE(channel,cash_environment,merchant,refund_number)
);
CREATE TRIGGER immutable_legacy_refund_deployment BEFORE UPDATE OR DELETE ON meton_inbox.legacy_refund_deployments FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
CREATE TRIGGER immutable_legacy_sender_retirements BEFORE UPDATE OR DELETE ON meton_inbox.legacy_sender_retirements FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
CREATE TRIGGER immutable_legacy_refund_return BEFORE UPDATE OR DELETE ON meton_inbox.legacy_refund_returns FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.legacy_refund_deployments ENABLE ALWAYS TRIGGER immutable_legacy_refund_deployment;
ALTER TABLE meton_inbox.legacy_sender_retirements ENABLE ALWAYS TRIGGER immutable_legacy_sender_retirements;
ALTER TABLE meton_inbox.legacy_refund_returns ENABLE ALWAYS TRIGGER immutable_legacy_refund_return;
REVOKE ALL ON meton_inbox.legacy_refund_deployments,meton_inbox.legacy_sender_retirements,meton_inbox.legacy_refund_returns FROM PUBLIC;

CREATE FUNCTION meton_inbox.require_legacy_refund_reviewer(s jsonb,inst text,purpose text) RETURNS meton_inbox.legacy_refund_deployments
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE policy meton_inbox.legacy_refund_deployments; a meton_inbox.refund_gate_authorities;
BEGIN
    SELECT * INTO policy FROM meton_inbox.legacy_refund_deployments WHERE (deployment,source,epoch,provider_instance)=
        (s->>'deployment',s->>'source',(s->>'epoch')::bigint,inst) FOR SHARE;
    SELECT * INTO a FROM meton_inbox.refund_gate_authorities WHERE (deployment,source,epoch,key_ref,source_system)=
        (s->>'deployment',s->>'source',(s->>'epoch')::bigint,(s->>'keyRef')::uuid,s->>'sourceSystem') FOR SHARE;
    IF a.key_ref IS NULL OR policy.provider_instance IS NULL OR s->>'inboxSystem' IS DISTINCT FROM meton_inbox.system_id() OR a.source_system=meton_inbox.system_id()
        OR purpose IS NULL OR purpose NOT IN ('retire','review') OR session_user IS DISTINCT FROM (CASE WHEN purpose='retire' THEN policy.retirement_role ELSE policy.review_role END)
        OR session_user IN (a.sender,a.stopper) OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_inbox','CREATE') OR
        EXISTS(SELECT FROM pg_roles r WHERE (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolbypassrls OR r.rolreplication) AND pg_has_role(session_user,r.oid,'MEMBER')) OR
        EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
            (has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE') OR has_table_privilege(session_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) OR
        pg_is_in_recovery() OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') OR
        current_setting('transaction_isolation')<>'read committed' OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'current historical reconciliation authority required' USING ERRCODE='42501'; END IF;
    RETURN policy;
END $$;

CREATE FUNCTION meton_inbox.record_legacy_sender_retirement(s jsonb,inst text,actor_id text,credential text,retirement_ref text,drain_ref text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p meton_inbox.legacy_refund_deployments:=meton_inbox.require_legacy_refund_reviewer(s,inst,'retire');
BEGIN
    IF num_nulls(actor_id,credential,retirement_ref,drain_ref)>0 OR length(actor_id) NOT BETWEEN 1 AND 128 OR credential!~'^[0-9a-f]{64}$' OR
        p.inventory->>actor_id IS DISTINCT FROM credential OR retirement_ref!~'^[0-9a-f]{64}$' OR drain_ref!~'^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'expected historical writer or retirement records differ' USING ERRCODE='22023'; END IF;
    INSERT INTO meton_inbox.legacy_sender_retirements(deployment,source,epoch,provider_instance,actor,credential_ref,retirement_evidence,drain_evidence)
        VALUES(p.deployment,p.source,p.epoch,inst,actor_id,credential,retirement_ref,drain_ref) ON CONFLICT DO NOTHING;
    IF NOT EXISTS(SELECT FROM meton_inbox.legacy_sender_retirements a WHERE (a.deployment,a.source,a.epoch,a.provider_instance,a.actor,
        a.credential_ref,a.retirement_evidence,a.drain_evidence)=(p.deployment,p.source,p.epoch,inst,actor_id,credential,retirement_ref,drain_ref)) THEN
        RAISE EXCEPTION 'historical writer receipt conflicts' USING ERRCODE='23505'; END IF;
END $$;

-- 审核员提供完整旧尝试清单及原来源分配依据；每个渠道终态都要另外从原验签收件恢复。
CREATE FUNCTION meton_inbox.review_legacy_refund_return(s jsonb,target jsonb,permit text,manifest jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p meton_inbox.legacy_refund_deployments:=meton_inbox.require_legacy_refund_reviewer(s,target->>'providerInstance','review');
    secret bytea; line jsonb; sample meton_inbox.refund_terminal_facts; entry meton_inbox.legacy_refund_returns;
    refs jsonb; seals jsonb:='[]'; orig bytea; facts jsonb; original_number text:=target->>'refundOrder';
    expected_origin jsonb:=jsonb_build_object('version',1,'legacyCutoff',target->>'cutoff','legacyOrder',target->>'order','legacyAudit',target->>'auditHash',
        'sourceMarker',target->>'marker','user',target->>'user','account',target->>'account','creation',target->>'creation','order',target->>'trade',
        'channel',p.channel,'cashEnvironment',p.cash_environment,'merchant',p.merchant,'app',p.app,'currency','CNY',
        'priceFen',target->>'paidFen','providerInstance',p.provider_instance);
BEGIN
    SELECT seal_key INTO STRICT secret FROM meton_inbox.refund_gate_authorities WHERE (deployment,source,epoch)=(p.deployment,p.source,p.epoch);
    IF permit IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.legacy.refund.debit.v1',s,target)::text,'UTF8'),secret),'hex')
        OR (target->>'channel',target->>'cashEnvironment',target->>'merchant',target->>'app') IS DISTINCT FROM (p.channel,p.cash_environment,p.merchant,p.app) THEN
        RAISE EXCEPTION 'wrong historical source or route' USING ERRCODE='42501'; END IF;
    IF (jsonb_typeof(manifest)='object' AND (manifest-ARRAY['evidence','unit','attempts','allocations'])='{}'::jsonb AND
        manifest->>'evidence'~'^[0-9a-f]{64}$' AND manifest->>'unit'~'^[A-Za-z0-9_.-]{1,120}$' AND octet_length(manifest::text)<=262144 AND
        jsonb_typeof(manifest->'attempts')='array' AND jsonb_array_length(manifest->'attempts') BETWEEN 1 AND 100 AND
        jsonb_typeof(manifest->'allocations')='array' AND jsonb_array_length(manifest->'allocations')<=1000) IS NOT TRUE OR
        EXISTS(SELECT FROM jsonb_array_elements(manifest->'attempts') x WHERE (jsonb_typeof(x)='object' AND x-ARRAY['refundOrder','refundFen','evidence']='{}'::jsonb
            AND length(x->>'refundOrder') BETWEEN 1 AND 64 AND x->>'refundFen'~'^[1-9][0-9]{0,18}$' AND (x->>'refundFen')::numeric<=(target->>'paidFen')::numeric
            AND x->>'evidence'~'^[0-9a-f]{64}$') IS NOT TRUE) OR
        (SELECT count(DISTINCT x->>'refundOrder') FROM jsonb_array_elements(manifest->'attempts') x)<>jsonb_array_length(manifest->'attempts') OR
        NOT EXISTS(SELECT FROM jsonb_array_elements(manifest->'attempts') x WHERE (x->>'refundOrder',x->>'refundFen')=(original_number,target->>'refundFen')) OR
        EXISTS(SELECT FROM jsonb_array_elements(manifest->'allocations') x WHERE (jsonb_typeof(x)='object' AND x-ARRAY['kind','nativeId','origin','units','evidence']='{}'::jsonb
            AND x->>'kind' IN ('grant','purchase') AND x->>'nativeId'~'^[1-9][0-9]{0,17}$' AND (x->>'origin')::uuid<>'00000000-0000-0000-0000-000000000000'::uuid
            AND x->>'units'~'^(0|[1-9][0-9]{0,11})[.][0-9]{8}$' AND (x->>'units')::numeric>0 AND x->>'evidence'~'^[0-9a-f]{64}$') IS NOT TRUE) OR
        (SELECT count(DISTINCT (x->>'kind',x->>'nativeId')) FROM jsonb_array_elements(manifest->'allocations') x)<>jsonb_array_length(manifest->'allocations') OR
        (SELECT coalesce(sum((x->>'units')::numeric),0) FROM jsonb_array_elements(manifest->'allocations') x) IS DISTINCT FROM
            (CASE target->>'state' WHEN 'held' THEN (target->>'units')::numeric WHEN 'returned' THEN 0 END) THEN
        RAISE EXCEPTION 'incomplete historical refund evidence or allocation' USING ERRCODE='22023'; END IF;
    IF EXISTS(SELECT FROM jsonb_each_text(p.inventory) actor WHERE NOT EXISTS(SELECT FROM meton_inbox.legacy_sender_retirements a WHERE
        (a.deployment,a.source,a.epoch,a.provider_instance,a.actor,a.credential_ref)=(p.deployment,p.source,p.epoch,p.provider_instance,actor.key,actor.value)
        AND a.recorded_xid<>pg_current_xact_id())) THEN RETURN jsonb_build_object('state','writers_pending'); END IF;
    SELECT jsonb_object_agg(a.actor,jsonb_build_array(a.credential_ref,a.retirement_evidence,a.drain_evidence)) INTO refs
        FROM meton_inbox.legacy_sender_retirements a WHERE (a.deployment,a.source,a.epoch,a.provider_instance)=(p.deployment,p.source,p.epoch,p.provider_instance);
    orig:=meton_inbox.lock_original_cash(jsonb_build_object('channel',p.channel,'cashEnvironment',p.cash_environment,'merchant',p.merchant,'app',p.app),
        target->>'trade',target->>'transaction');
    IF EXISTS(SELECT FROM meton_inbox.unindexed_refunds x WHERE (x.channel,x.cash_environment,x.merchant)=(p.channel,p.cash_environment,p.merchant)) OR
        EXISTS(SELECT FROM meton_inbox.refund_evidence i JOIN meton_inbox.receipts r USING(receipt) LEFT JOIN meton_inbox.refund_terminal_facts k
            ON (k.receipt,k.digest)=(i.receipt,i.digest) WHERE (r.channel,r.cash_environment,r.merchant)=(p.channel,p.cash_environment,p.merchant) AND k.receipt IS NULL) THEN
        RETURN jsonb_build_object('state','evidence_pending'); END IF;
    IF EXISTS(SELECT FROM meton_inbox.refund_terminal_facts k WHERE k.original=orig AND NOT EXISTS(SELECT FROM jsonb_array_elements(manifest->'attempts') x
        WHERE x->>'refundOrder'=k.outcome->>'refundOrder')) THEN RETURN jsonb_build_object('state','review'); END IF;
    FOR line IN SELECT value FROM jsonb_array_elements(manifest->'attempts') ORDER BY value->>'refundOrder' LOOP
        SELECT * INTO sample FROM meton_inbox.refund_terminal_facts k WHERE (k.original,k.outcome->>'refundOrder')=(orig,line->>'refundOrder')
            ORDER BY k.receipt,k.digest LIMIT 1;
        IF NOT FOUND THEN RETURN jsonb_build_object('state','evidence_pending'); END IF;
        IF sample.origin IS DISTINCT FROM expected_origin OR sample.outcome->>'state' IS DISTINCT FROM 'CLOSED' OR
            sample.seen_xid=pg_current_xact_id() OR (sample.outcome->>'refundFen')::bigint<>(line->>'refundFen')::bigint OR
            (sample.outcome->>'total')::bigint<>(target->>'paidFen')::bigint OR (sample.outcome->>'payerTotal')::bigint NOT BETWEEN 0 AND (sample.outcome->>'total')::bigint OR
            EXISTS(SELECT FROM meton_inbox.refund_terminal_facts x WHERE (x.channel,x.cash_environment,x.merchant)=(p.channel,p.cash_environment,p.merchant)
                AND (x.outcome->>'refundOrder'=line->>'refundOrder' OR x.outcome->>'refundID'=sample.outcome->>'refundID')
                AND (x.original<>orig OR x.origin<>sample.origin OR x.outcome-'occurredAt'<>sample.outcome-'occurredAt')) OR
            EXISTS(SELECT FROM meton_inbox.proofs v JOIN meton_inbox.refund_terminal_facts x USING(receipt) WHERE x.original=orig
                AND x.outcome->>'refundOrder'=line->>'refundOrder' AND NOT v.first_proof) THEN RETURN jsonb_build_object('state','review'); END IF;
        seals:=seals||jsonb_build_array(jsonb_build_object('attempt',line->>'refundOrder','providerRefund',sample.outcome->>'refundID','fen',line->>'refundFen'));
    END LOOP;
    INSERT INTO meton_inbox.legacy_refund_returns(marker,native_order,channel,cash_environment,merchant,refund_number,scope,target,manifest,retirements,closure_proofs)
        VALUES((target->>'marker')::uuid,(target->>'order')::bigint,p.channel,p.cash_environment,p.merchant,original_number,s,target,manifest,refs,seals) ON CONFLICT DO NOTHING;
    SELECT * INTO entry FROM meton_inbox.legacy_refund_returns a WHERE (a.marker,a.native_order)=((target->>'marker')::uuid,(target->>'order')::bigint);
    IF entry.marker IS NULL OR (entry.scope,entry.target,entry.manifest,entry.retirements,entry.closure_proofs) IS DISTINCT FROM (s,target,manifest,refs,seals) THEN
        RAISE EXCEPTION 'original historical refund decision conflicts' USING ERRCODE='23505'; END IF;
    IF entry.approved_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    facts:=jsonb_build_object('format',1,'scope',entry.scope,'target',entry.target,'manifest',entry.manifest,'retirements',entry.retirements,
        'inventoryEvidence',p.inventory_evidence,'closures',entry.closure_proofs,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','proved','facts',facts,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.legacy.refund.return.v1',facts)::text,'UTF8'),secret),'hex'));
END $$;
REVOKE ALL ON FUNCTION meton_inbox.require_legacy_refund_reviewer(jsonb,text,text),meton_inbox.record_legacy_sender_retirement(jsonb,text,text,text,text,text),
    meton_inbox.review_legacy_refund_return(jsonb,jsonb,text,jsonb) FROM PUBLIC;
