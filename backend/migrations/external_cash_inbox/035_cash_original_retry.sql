-- 查询与受限重试共用同一原事项投影；无权限的内部构造函数不独立授予读取或写入资格。
DO $extract$
DECLARE body text:=pg_get_functiondef('meton_inbox.cash_archive_operations_page(jsonb,text,integer,text)'::regprocedure);
    field text; expression text;
BEGIN
    IF cardinality(string_to_array(body,'r:=meton_inbox.require_cash_archive_reader(route);'))<>2 OR
        cardinality(string_to_array(body,'r meton_inbox.cash_archive_readers;'))<>2 THEN RAISE EXCEPTION 'archive page boundary changed'; END IF;
    body:=replace(body,'meton_inbox.cash_archive_operations_page(','meton_inbox.cash_archive_operations_snapshot(');
    body:=replace(replace(body,'r:=meton_inbox.require_cash_archive_reader(route);',''),'r meton_inbox.cash_archive_readers;','');
    FOREACH field IN ARRAY ARRAY['deployment','source_system','cash_environment','source','epoch','key_ref','channel','merchant'] LOOP
        expression:=CASE field WHEN 'source_system' THEN '(route->>''sourceSystem'')' WHEN 'cash_environment' THEN '(route->>''cashEnvironment'')'
            WHEN 'key_ref' THEN '(route->>''keyRef'')::uuid' WHEN 'epoch' THEN '(route->>''epoch'')::bigint' ELSE '(route->>'''||field||''')' END;
        body:=replace(body,'r.'||field,expression);
    END LOOP;
    EXECUTE body;
END $extract$;
REVOKE ALL ON FUNCTION meton_inbox.cash_archive_operations_snapshot(jsonb,text,integer,text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION meton_inbox.cash_archive_operations_page(route jsonb,p_after text,p_size integer,p_key text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.require_cash_archive_reader(route);
    RETURN meton_inbox.cash_archive_operations_snapshot(route,p_after,p_size,p_key);
END $$;

CREATE TABLE meton_inbox.cash_retry_controllers(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),key_ref uuid NOT NULL,
    source_system text NOT NULL,channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,
    controller name NOT NULL UNIQUE,PRIMARY KEY(deployment,source,epoch,key_ref,channel,cash_environment,merchant)
);
CREATE TABLE meton_inbox.cash_retry_receipts(
    deployment text NOT NULL,source text NOT NULL,operation uuid NOT NULL,scope jsonb NOT NULL,original_key text NOT NULL,
    request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),actor jsonb NOT NULL,receipt jsonb NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(deployment,source,operation)
);
DO $protect$ DECLARE table_name text; BEGIN
    FOREACH table_name IN ARRAY ARRAY['cash_retry_controllers','cash_retry_receipts'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',table_name);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',table_name);
        EXECUTE format('REVOKE ALL ON meton_inbox.%I FROM PUBLIC',table_name);
    END LOOP;
END $protect$;

/** 同一事务锁住当前执行范围；专用重试身份不能拥有直接表访问、通知解密或现金执行权限。 */
CREATE FUNCTION meton_inbox.lock_cash_retry_controller(route jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_inbox.cash_retry_controllers;
BEGIN
    IF jsonb_typeof(route) IS DISTINCT FROM 'object' OR
        (route ?& ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']) IS NOT TRUE OR
        route-ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']<>'{}'::jsonb OR
        current_setting('transaction_read_only')<>'off' OR current_setting('transaction_isolation')<>'read committed' OR
        pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR current_setting('fsync')<>'on' OR
        current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') THEN
        RAISE EXCEPTION 'current durable cash retry scope required' USING ERRCODE='25006'; END IF;
    SELECT x.* INTO r FROM meton_inbox.cash_retry_controllers x JOIN meton_inbox.refund_gate_authorities a
        USING(deployment,source,epoch,key_ref,source_system)
        WHERE (x.deployment,x.source,x.epoch,x.key_ref,x.source_system,x.channel,x.cash_environment,x.merchant,x.controller)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,(route->>'keyRef')::uuid,route->>'sourceSystem',
             route->>'channel',route->>'cashEnvironment',route->>'merchant',session_user::name)
        AND meton_inbox.system_id()=route->>'inboxSystem' AND x.source_system<>meton_inbox.system_id() FOR SHARE OF x,a;
    IF r.controller IS NULL THEN RAISE EXCEPTION 'cash retry controller retired' USING ERRCODE='42501'; END IF;
    PERFORM FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(r.channel,r.cash_environment,r.merchant) FOR SHARE;
    IF NOT FOUND OR EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(r.channel,r.cash_environment,r.merchant) AND
        (w.deployment,w.source_name,w.generation,w.source_system)<>(r.deployment,r.source,r.epoch,r.source_system)) OR
        EXISTS(SELECT FROM pg_roles p WHERE p.rolname=session_user AND (p.rolsuper OR p.rolinherit OR p.rolcreatedb OR p.rolcreaterole OR p.rolreplication OR p.rolbypassrls)) OR
        EXISTS(SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=session_user)) OR
        has_schema_privilege(session_user,'meton_inbox','CREATE') OR has_schema_privilege(session_user,'public','CREATE') OR
        EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
            (has_table_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
             has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) OR
        EXISTS(SELECT FROM pg_proc p WHERE p.pronamespace='meton_inbox'::regnamespace AND p.oid NOT IN
            ('meton_inbox.system_id()'::regprocedure,'meton_inbox.cash_original_retry_ready(jsonb)'::regprocedure,
             'meton_inbox.cash_original_retry(jsonb,jsonb,text)'::regprocedure) AND has_function_privilege(session_user,p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'separate current cash retry controller required' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION meton_inbox.cash_original_retry_ready(route jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN PERFORM meton_inbox.lock_cash_retry_controller(route); RETURN true; END $$;

/** 重试只调整原队列的待检查时间。租约、派发状态、资金占用及全部付款／退款编号保持原值。 */
CREATE FUNCTION meton_inbox.cash_original_retry(route jsonb,q jsonb,action text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE op uuid; request_hash bytea; saved meton_inbox.cash_retry_receipts; item jsonb; result jsonb;
    key text:=q->>'originalKey'; kind text; ref uuid; proof bytea; affected integer:=0; changed integer; busy boolean:=false;
    outcome text; now_at timestamptz:=clock_timestamp();
BEGIN
    PERFORM meton_inbox.lock_cash_retry_controller(route);
    IF action IS NULL OR action NOT IN ('retry','result') OR jsonb_typeof(q) IS DISTINCT FROM 'object' OR
        (q ?& ARRAY['format','operation','originalKey','basisDigest','person','personVersion','role','intentDigest','until']) IS NOT TRUE OR
        q-ARRAY['format','operation','originalKey','basisDigest','person','personVersion','role','intentDigest','until']<>'{}'::jsonb OR
        (q->>'format'='1' AND q->>'operation'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND
         q->>'person'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND q->>'personVersion'~'^[1-9][0-9]{0,17}$' AND
         q->>'basisDigest'~'^[0-9a-f]{64}$' AND q->>'intentDigest'~'^[0-9a-f]{64}$' AND
         q->>'role' IN ('reader','intake','reviewer') AND (action='result' OR q->>'role' IN ('intake','reviewer')) AND
         (q->>'until')::timestamptz>clock_timestamp() AND (q->>'until')::timestamptz<=clock_timestamp()+interval '30 seconds' AND
         octet_length(q::text)<=4096) IS NOT TRUE THEN RAISE EXCEPTION 'bounded current cash retry request required' USING ERRCODE='22023'; END IF;
    op:=(q->>'operation')::uuid;
    IF op='00000000-0000-0000-0000-000000000000'::uuid OR (q->>'person')::uuid='00000000-0000-0000-0000-000000000000'::uuid THEN
        RAISE EXCEPTION 'original command and operator required' USING ERRCODE='22023'; END IF;
    IF key IS NULL OR key !~ '^(refund|alternative|dispute)/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND
        key !~ '^proof/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'exact original retry key required' USING ERRCODE='22023'; END IF;
    kind:=split_part(key,'/',1);ref:=split_part(key,'/',2)::uuid;
    request_hash:=sha256(convert_to(jsonb_build_array('meton.cash.original.retry.v1',route,q-ARRAY['person','personVersion','role','intentDigest','until'])::text,'UTF8'));
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.cash.original.retry.v1/'||jsonb_build_array(route->>'deployment',route->>'source',op)::text,0));
    SELECT * INTO saved FROM meton_inbox.cash_retry_receipts WHERE (deployment,source,operation)=(route->>'deployment',route->>'source',op);
    IF (q->>'until')::timestamptz<=clock_timestamp() THEN RAISE EXCEPTION 'cash retry authorization expired' USING ERRCODE='42501'; END IF;
    IF saved.operation IS NOT NULL THEN
        IF saved.scope IS DISTINCT FROM route OR saved.original_key IS DISTINCT FROM key OR saved.request_hash<>request_hash THEN
            RAISE EXCEPTION 'cash retry command reused' USING ERRCODE='23505'; END IF;
        RETURN saved.receipt;
    END IF;
    IF action='result' THEN RETURN jsonb_build_object('format',1,'state','operation_unknown','operation',op,'originalKey',key,
        'financialAuthority',false,'executionAuthorized',false); END IF;
    -- 先锁本笔原队列，再用与读取相同的构造核对当前依据；不会撤掉正在执行的租约来抢占工作。
    IF kind='proof' THEN
        proof:=decode(split_part(key,'/',3),'hex');
        PERFORM FROM meton_inbox.purchase_delivery d WHERE (d.receipt,d.digest,d.deployment,d.source_name)=
            (ref,proof,route->>'deployment',route->>'source') ORDER BY d.app FOR UPDATE;
        PERFORM FROM meton_inbox.cash_notice_origin_jobs j WHERE (j.receipt,j.digest,j.deployment,j.source)=
            (ref,proof,route->>'deployment',route->>'source') ORDER BY j.app FOR UPDATE;
    ELSIF kind='refund' THEN PERFORM FROM meton_inbox.refund_settlement_work WHERE refund=ref FOR UPDATE;
    ELSIF kind='alternative' THEN PERFORM FROM meton_inbox.alternative_cash_jobs WHERE refund=ref FOR UPDATE;
    END IF;
    item:=meton_inbox.cash_archive_operations_snapshot(route,NULL,1,key)#>'{items,0}';
    IF item IS NULL THEN outcome:='original_unavailable';
    ELSIF item->>'basisDigest' IS DISTINCT FROM q->>'basisDigest' THEN outcome:='basis_changed';
    ELSIF kind='proof' THEN
        UPDATE meton_inbox.purchase_delivery SET available_at=least(available_at,now_at) WHERE
            (receipt,digest,deployment,source_name)=(ref,proof,route->>'deployment',route->>'source') AND state='retry';
        GET DIAGNOSTICS affected=ROW_COUNT;
        UPDATE meton_inbox.cash_notice_origin_jobs SET available_at=least(available_at,now_at) WHERE
            (receipt,digest,deployment,source,epoch)=(ref,proof,route->>'deployment',route->>'source',(route->>'epoch')::bigint) AND state='retry';
        GET DIAGNOSTICS changed=ROW_COUNT;affected:=affected+changed;
        busy:=EXISTS(SELECT FROM meton_inbox.purchase_delivery WHERE (receipt,digest,deployment,source_name)=
            (ref,proof,route->>'deployment',route->>'source') AND state='claimed') OR
            EXISTS(SELECT FROM meton_inbox.cash_notice_origin_jobs WHERE (receipt,digest,deployment,source)=
            (ref,proof,route->>'deployment',route->>'source') AND state='claimed');
    ELSIF kind='refund' THEN
        UPDATE meton_inbox.refund_settlement_work SET next_at=least(next_at,now_at) WHERE refund=ref AND token IS NULL AND last_state NOT IN ('settled','released');
        GET DIAGNOSTICS affected=ROW_COUNT;
        busy:=EXISTS(SELECT FROM meton_inbox.refund_settlement_work WHERE refund=ref AND token IS NOT NULL);
    ELSIF kind='alternative' THEN
        UPDATE meton_inbox.alternative_cash_jobs j SET next_at=least(j.next_at,now_at) FROM meton_inbox.refund_alternative_decisions d
            WHERE j.refund=ref AND j.refund=d.refund AND d.choice='reserved' AND j.token IS NULL AND j.state NOT IN ('success','closed');
        GET DIAGNOSTICS affected=ROW_COUNT;
        busy:=EXISTS(SELECT FROM meton_inbox.alternative_cash_jobs WHERE refund=ref AND token IS NOT NULL);
    ELSE outcome:='review_required';
    END IF;
    outcome:=coalesce(outcome,CASE WHEN affected>0 THEN 'queued' WHEN busy THEN 'original_busy' ELSE 'original_not_scheduled' END);
    result:=jsonb_build_object('format',1,'state',outcome,'operation',op,'originalKey',key,'basisDigest',q->>'basisDigest',
        'scope',route,'scheduled',affected,'busy',busy,'financialAuthority',false,'executionAuthorized',false);
    IF (q->>'until')::timestamptz<=clock_timestamp() THEN RAISE EXCEPTION 'cash retry authorization expired' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.cash_retry_receipts(deployment,source,operation,scope,original_key,request_hash,actor,receipt)
        VALUES(route->>'deployment',route->>'source',op,route,key,request_hash,
            jsonb_build_object('person',q->'person','version',q->'personVersion','role',q->'role','intentDigest',q->'intentDigest'),result);
    RETURN result;
END $$;
REVOKE ALL ON FUNCTION meton_inbox.lock_cash_retry_controller(jsonb),meton_inbox.cash_original_retry_ready(jsonb),meton_inbox.cash_original_retry(jsonb,jsonb,text) FROM PUBLIC;
