/** 归档只能提交当前签发的精确关联。原账号、原退款和当前账务仍由来源库决定，缺失不等于结清。 */
CREATE FUNCTION meton_ledger.read_cash_archive_original(route jsonb,proof jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE a meton_ledger.refund_gate_authorities; f jsonb:=proof->'facts'; link jsonb:=f->'link'; item jsonb:=f->'item';
    g meton_ledger.refund_gate_origins; m public.meton_managed_creations; d meton_ledger.cash_dispute_statuses;
    owner jsonb; source_key text; original jsonb; state text:='original_unavailable'; value jsonb;
BEGIN
    IF current_setting('transaction_read_only')<>'on' OR current_setting('transaction_isolation')<>'read committed' OR
        pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'current read-only source required' USING ERRCODE='25006'; END IF;
    IF (jsonb_typeof(route)='object' AND jsonb_typeof(proof)='object' AND proof-ARRAY['facts','mac']='{}'::jsonb AND
        route ?& ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant'] AND
        route-ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']='{}'::jsonb AND
        octet_length(proof::text)<=33792) IS NOT TRUE THEN
        RAISE EXCEPTION 'bounded exact archive proof required' USING ERRCODE='22023'; END IF;
    SELECT x.* INTO a FROM meton_ledger.refund_gate_authorities x JOIN public.meton_managed_fence n ON
        (n.environment,n.source,n.epoch)=(x.deployment,x.source,x.epoch) AND n.singleton AND n.enabled
        JOIN meton_ledger.cash_operations_readers r ON (r.deployment,r.source,r.epoch)=(x.deployment,x.source,x.epoch)
        WHERE (x.deployment,x.source,x.epoch,x.key_ref,x.inbox_system,r.reader)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,(route->>'keyRef')::uuid,route->>'inboxSystem',session_user);
    IF a.key_ref IS NULL OR route->>'sourceSystem' IS DISTINCT FROM meton_ledger.notification_system_id() OR
        a.inbox_system=route->>'sourceSystem' OR f->'scope' IS DISTINCT FROM route OR
        f->>'format' IS DISTINCT FROM '1' OR f->>'purpose' IS DISTINCT FROM 'cash.archive.original.read.v1' OR
        ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(
            convert_to(jsonb_build_array('meton.cash.archive.original.read.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'current exact archive proof required' USING ERRCODE='42501'; END IF;
    IF EXISTS(SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=session_user)) OR
        EXISTS(SELECT FROM pg_roles p WHERE p.rolname=session_user AND (p.rolsuper OR p.rolcreaterole OR p.rolcreatedb OR p.rolreplication OR p.rolbypassrls OR p.rolinherit)) OR
        has_schema_privilege(session_user,'meton_ledger','CREATE') OR
        EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p') AND
            (has_table_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) OR
        EXISTS(SELECT FROM pg_proc p WHERE p.pronamespace='meton_ledger'::regnamespace AND p.prosecdef AND p.oid NOT IN
            ('meton_ledger.read_cash_operations(jsonb,text,integer)'::regprocedure,'meton_ledger.read_cash_operation(jsonb,text)'::regprocedure,
             'meton_ledger.read_cash_archive_original(jsonb,jsonb)'::regprocedure) AND has_function_privilege(session_user,p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'separate current cash operations reader required' USING ERRCODE='42501'; END IF;

    IF item IS NULL OR item='null'::jsonb THEN state:='original_unavailable';
    ELSIF link IS NULL OR link='null'::jsonb THEN state:='original_unlinked';
    ELSIF link->>'kind'='refund' AND item#>>'{value,kind}' IN ('refund','alternative') THEN
        SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE refund=(link#>>'{target,refund}')::uuid;
        IF g.refund IS NOT NULL AND g.target=link->'target' AND item#>>'{value,refund}'=g.refund::text THEN
            SELECT * INTO m FROM public.meton_managed_creations WHERE
                (source_marker,environment,source,epoch)=(g.marker,a.deployment,a.source,a.epoch);
            IF m.source_marker IS NOT NULL AND meton_ledger.refund_owner_succeeded(m,g.accepted_epoch) THEN source_key:='refund/'||g.refund::text; END IF;
        END IF;
    ELSIF link->>'kind'='dispute' AND item#>>'{value,kind}'='dispute' THEN
        SELECT * INTO d FROM meton_ledger.cash_dispute_statuses WHERE dispute=(link->>'ref')::uuid ORDER BY revision DESC LIMIT 1;
        IF d.dispute IS NOT NULL AND item#>>'{value,dispute}'=d.dispute::text AND d.value->'owner'=link->'owner' AND
            d.revision=(link->>'revision')::bigint AND d.value->>'cashHash'=link->>'cashHash' THEN
            SELECT * INTO m FROM public.meton_managed_creations WHERE
                (source_marker,environment,source,epoch)=(d.marker,a.deployment,a.source,a.epoch);
            IF m.source_marker IS NOT NULL AND m.meton_user::text=link#>>'{owner,0}' AND m.account::text=link#>>'{owner,1}' THEN
                source_key:='dispute/'||d.dispute::text;
            END IF;
        END IF;
    END IF;
    IF source_key IS NOT NULL THEN
        owner:=jsonb_build_object('environment',m.environment,'source',m.source,'epoch',m.epoch,'user',m.meton_user,'account',m.account,
            'creation',m.operation,'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker,'source_system',route->>'sourceSystem');
        -- 复用原清单的范围与分类，不复制资金终态算法，不把归档原绑定当成当前账户授权。
        original:=meton_ledger.cash_operations_page(owner,NULL,1,source_key)#>'{items,0}';
        IF original IS NOT NULL THEN state:='observed'; END IF;
    END IF;
    value:=jsonb_build_object('format',1,'state',state,'scope',route,'scopeKey',f->>'scopeKey','originalKey',f->>'originalKey',
        'archiveBasisDigest',item->>'basisDigest','original',original,'observedAt',clock_timestamp(),
        'financialAuthority',false,'executionAuthorized',false);
    RETURN value||jsonb_build_object('basisDigest',encode(sha256(convert_to(jsonb_build_array(
        'meton.cash.archive.original.observation.v1',value-'observedAt')::text,'UTF8')),'hex'));
END $$;
REVOKE ALL ON FUNCTION meton_ledger.read_cash_archive_original(jsonb,jsonb) FROM PUBLIC;
