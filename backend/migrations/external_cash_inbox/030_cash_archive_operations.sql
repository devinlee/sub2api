-- 待归属通知属于商户归档范围，不能借当前登录账号推断归属。此读取没有解密、领取或资金执行权。
CREATE TABLE meton_inbox.cash_archive_readers(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),key_ref uuid NOT NULL,
    source_system text NOT NULL,channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,
    reader name NOT NULL UNIQUE,PRIMARY KEY(deployment,source,epoch,key_ref,channel,cash_environment,merchant)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.cash_archive_readers
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.cash_archive_readers ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_inbox.cash_archive_readers FROM PUBLIC;

/** 范围明确覆盖当前商户的所有应用；若同商户混有其他来源，不允许假装只读本应用的未归属通知。 */
CREATE FUNCTION meton_inbox.require_cash_archive_reader(route jsonb) RETURNS meton_inbox.cash_archive_readers
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_inbox.cash_archive_readers;
BEGIN
    IF jsonb_typeof(route) IS DISTINCT FROM 'object' OR
        route-ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']<>'{}'::jsonb OR
        (SELECT count(*) FROM jsonb_object_keys(route))<>9 OR
        current_setting('transaction_read_only')<>'on' OR current_setting('transaction_isolation')<>'read committed' OR
        pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'read-only current archive scope required' USING ERRCODE='25006';
    END IF;
    SELECT x.* INTO r FROM meton_inbox.cash_archive_readers x JOIN meton_inbox.refund_gate_authorities a USING(deployment,source,epoch,key_ref,source_system)
        WHERE (x.deployment,x.source,x.epoch,x.key_ref,x.source_system,x.channel,x.cash_environment,x.merchant,x.reader)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,(route->>'keyRef')::uuid,route->>'sourceSystem',
             route->>'channel',route->>'cashEnvironment',route->>'merchant',session_user)
        AND meton_inbox.system_id()=route->>'inboxSystem' AND x.source_system<>meton_inbox.system_id();
    IF r.reader IS NULL OR NOT EXISTS(SELECT FROM meton_inbox.writers w WHERE
        (w.channel,w.cash_environment,w.merchant)=(r.channel,r.cash_environment,r.merchant)) OR
        EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(r.channel,r.cash_environment,r.merchant)
            AND (w.deployment,w.source_name,w.generation,w.source_system)<>(r.deployment,r.source,r.epoch,r.source_system)) OR
        EXISTS(SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=session_user)) OR
        EXISTS(SELECT FROM pg_roles p WHERE p.rolname=session_user AND
            (p.rolsuper OR p.rolcreaterole OR p.rolcreatedb OR p.rolreplication OR p.rolbypassrls OR p.rolinherit)) OR
        has_schema_privilege(session_user,'meton_inbox','CREATE') OR
        EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
            (has_table_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
             has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) OR
        EXISTS(SELECT FROM pg_proc p WHERE p.pronamespace='meton_inbox'::regnamespace AND p.prosecdef AND
            p.oid<>'meton_inbox.read_cash_archive_operations(jsonb,text,integer)'::regprocedure AND has_function_privilege(session_user,p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'separate current archive reader required' USING ERRCODE='42501';
    END IF;
    RETURN r;
END $$;

/** 各页仅描述当前归档，不与来源库构造伪原子快照；已投递也不等于来源已结清。 */
CREATE FUNCTION meton_inbox.read_cash_archive_operations(route jsonb,p_after text,p_size integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_inbox.cash_archive_readers;page jsonb;answer jsonb;observed timestamptz:=clock_timestamp();scope_key text;
BEGIN
    r:=meton_inbox.require_cash_archive_reader(route);
    IF p_size IS NULL OR p_size NOT BETWEEN 1 AND 100 OR
        (p_after IS NOT NULL AND (length(p_after)>220 OR p_after !~ '^[a-z_]+/[A-Za-z0-9_./:-]{1,200}$')) THEN
        RAISE EXCEPTION 'bounded archive page required' USING ERRCODE='22023';
    END IF;
    scope_key:=encode(sha256(convert_to(jsonb_build_array('meton.cash.archive.scope.v1',r.deployment,r.source,r.source_system,
        meton_inbox.system_id(),r.channel,r.cash_environment,r.merchant)::text,'UTF8')),'hex');
    WITH items AS (
        SELECT 'proof/'||p.receipt::text||'/'||encode(p.digest,'hex') AS key,p.saved_at AS opened,
            jsonb_build_object('kind','proof','receipt',p.receipt,'proof',encode(p.digest,'hex'),'noticeKind',n.kind,
                'ownership','not_resolved_by_listing','firstSeen',n.first_seen,'firstProof',p.first_proof,
                'conflicted',EXISTS(SELECT FROM meton_inbox.proofs other WHERE other.receipt=p.receipt AND NOT other.first_proof),
                'unindexedRefund',EXISTS(SELECT FROM meton_inbox.unindexed_refunds u WHERE (u.receipt,u.digest)=(p.receipt,p.digest)),
                'scopeApps',(SELECT count(*) FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(r.channel,r.cash_environment,r.merchant)),
                'deliveries',coalesce((SELECT jsonb_object_agg(state,total) FROM
                    (SELECT d.state,count(*) AS total FROM meton_inbox.purchase_delivery d JOIN meton_inbox.writers w
                        ON (w.channel,w.cash_environment,w.merchant,w.app)=(r.channel,r.cash_environment,r.merchant,d.app)
                        WHERE (d.receipt,d.digest,d.deployment,d.source_name)=(p.receipt,p.digest,r.deployment,r.source)
                        GROUP BY d.state) counts),'{}'::jsonb)) AS value
        FROM meton_inbox.receipts n JOIN meton_inbox.proofs p USING(receipt)
        WHERE (n.channel,n.cash_environment,n.merchant)=(r.channel,r.cash_environment,r.merchant)
        UNION ALL
        SELECT 'refund/'||b.refund::text,g.created_at,
            jsonb_build_object('kind','refund','refund',b.refund,'ownership','original_binding',
                'initialMode',b.initial_mode,'gateChoice',g.choice,'state',coalesce(j.last_state,'work_missing'),
                'revision',j.revision,'hasLease',j.token IS NOT NULL,
                'nextCheckAt',CASE WHEN isfinite(j.next_at) THEN j.next_at ELSE NULL END,
                'cashObserved',EXISTS(SELECT FROM meton_inbox.refund_positive_cash x WHERE x.refund=b.refund),
                'cashConflict',EXISTS(SELECT FROM meton_inbox.refund_cash_disputes x WHERE x.refund=b.refund))
        FROM meton_inbox.refund_wire_bindings b LEFT JOIN meton_inbox.refund_settlement_work j USING(refund)
            LEFT JOIN meton_inbox.refund_gate_decisions g USING(refund)
        WHERE (b.channel,b.cash_environment,b.merchant,b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}')=
            (r.channel,r.cash_environment,r.merchant,r.deployment,r.source)
        UNION ALL
        SELECT 'alternative/'||d.refund::text,NULL::timestamptz,
            jsonb_build_object('kind','alternative','refund',d.refund,'ownership','original_binding','choice',d.choice,
                'state',coalesce(j.state,'work_missing'),'hasLease',j.token IS NOT NULL,
                'nextCheckAt',CASE WHEN isfinite(j.next_at) THEN j.next_at ELSE NULL END,
                'cashObserved',EXISTS(SELECT FROM meton_inbox.alternative_cash_positive x WHERE x.refund=d.refund))
        FROM meton_inbox.refund_alternative_decisions d LEFT JOIN meton_inbox.alternative_cash_jobs j USING(refund)
        WHERE (d.proposal#>>'{envelope,scope,channel}',d.proposal#>>'{envelope,scope,cashEnvironment}',d.proposal#>>'{envelope,scope,merchant}',
               d.proposal#>>'{envelope,scope,deployment}',d.proposal#>>'{envelope,scope,source}')=
            (r.channel,r.cash_environment,r.merchant,r.deployment,r.source)
        UNION ALL
        SELECT 'dispute/'||c.id::text,NULL::timestamptz,
            jsonb_build_object('kind','dispute','dispute',c.id,'ownership','original_binding','state',c.state,
                'revision',c.revision,'updatedAt',c.updated_at,'assigned',c.assigned_to IS NOT NULL,'assignmentEpoch',c.assigned_epoch,
                'evidenceEpoch',c.epoch,'requiresCurrentReview',c.epoch<>r.epoch OR c.key_ref<>r.key_ref)
        FROM meton_inbox.cash_dispute_cases c WHERE
            (c.origin#>>'{scope,channel}',c.origin#>>'{scope,cashEnvironment}',c.origin#>>'{scope,merchant}',c.origin#>>'{scope,deployment}',c.origin#>>'{scope,source}')=
            (r.channel,r.cash_environment,r.merchant,r.deployment,r.source)
    ),bounded AS (
        SELECT key,opened,value FROM items WHERE p_after IS NULL OR key COLLATE "C">p_after COLLATE "C"
            ORDER BY key COLLATE "C" LIMIT p_size+1
    ) SELECT coalesce(jsonb_agg(jsonb_build_object('key',key,'openedAt',opened,'value',value,
        'basisDigest',encode(sha256(convert_to(jsonb_build_array('meton.cash.archive.item.v1',scope_key,key,opened,value)::text,'UTF8')),'hex')) ORDER BY key COLLATE "C"),'[]'::jsonb)
        INTO page FROM bounded;
    answer:=jsonb_build_object('format',1,'state','observed','scope','merchant_archive_all_apps','scopeKey',scope_key,
        'environment',r.deployment,'source',r.source,'epoch',r.epoch,'keyRef',r.key_ref,'archiveSystem',meton_inbox.system_id(),
        'observedAt',observed,'after',p_after,'size',p_size,'more',jsonb_array_length(page)>p_size,
        'items',CASE WHEN jsonb_array_length(page)>p_size THEN page-p_size ELSE page END,
        'next',CASE WHEN jsonb_array_length(page)>0 THEN page->(least(jsonb_array_length(page),p_size)-1)->>'key' ELSE p_after END,
        'financialAuthority',false,'executionAuthorized',false);
    IF octet_length(answer::text)>196608 THEN RAISE EXCEPTION 'archive page too large' USING ERRCODE='54000'; END IF;
    RETURN answer;
END $$;
REVOKE ALL ON FUNCTION meton_inbox.require_cash_archive_reader(jsonb),meton_inbox.read_cash_archive_operations(jsonb,text,integer) FROM PUBLIC;
