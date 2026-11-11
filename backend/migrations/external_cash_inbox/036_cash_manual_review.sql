-- 人员证明与原审核结果同事务留证；财务状态仍只由既有原退款／争议流程解释。
CREATE TABLE meton_inbox.cash_review_controllers(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),key_ref uuid NOT NULL,
    source_system text NOT NULL,channel text NOT NULL,cash_environment text NOT NULL CHECK(cash_environment='isolated'),merchant text NOT NULL,
    controller name NOT NULL UNIQUE,PRIMARY KEY(deployment,source,epoch,key_ref,channel,cash_environment,merchant)
);
CREATE TABLE meton_inbox.cash_review_receipts(
    deployment text NOT NULL,source text NOT NULL,operation uuid NOT NULL,scope jsonb NOT NULL,original_key text NOT NULL,
    request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),actor jsonb NOT NULL,receipt jsonb NOT NULL,
    material_route text,material_key_ref text,
    CHECK((receipt->>'state'='recorded')=(material_route IS NOT NULL AND material_key_ref IS NOT NULL)),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(deployment,source,operation)
);
DO $protect$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['cash_review_controllers','cash_review_receipts'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
        EXECUTE format('REVOKE ALL ON meton_inbox.%I FROM PUBLIC',n);
    END LOOP;
END $protect$;

/** 服务连接和人员身份分开；本连接只能调用三项受限接缝，不能绕过人员回执直写原审核表。 */
CREATE FUNCTION meton_inbox.lock_cash_review_controller(route jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_inbox.cash_review_controllers;
BEGIN
    IF jsonb_typeof(route) IS DISTINCT FROM 'object' OR
        (route ?& ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']) IS NOT TRUE OR
        route-ARRAY['deployment','source','epoch','keyRef','sourceSystem','inboxSystem','channel','cashEnvironment','merchant']<>'{}'::jsonb OR
        route->>'cashEnvironment' IS DISTINCT FROM 'isolated' OR current_setting('transaction_read_only')<>'off' OR
        current_setting('transaction_isolation')<>'read committed' OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR
        current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') THEN
        RAISE EXCEPTION 'current durable isolated review scope required' USING ERRCODE='25006'; END IF;
    SELECT x.* INTO r FROM meton_inbox.cash_review_controllers x JOIN meton_inbox.refund_gate_authorities a
        USING(deployment,source,epoch,key_ref,source_system)
        JOIN meton_inbox.refund_aftercare_review_roles p USING(deployment,source,epoch,key_ref)
        WHERE (x.deployment,x.source,x.epoch,x.key_ref,x.source_system,x.channel,x.cash_environment,x.merchant,x.controller,p.reviewer)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,(route->>'keyRef')::uuid,route->>'sourceSystem',
             route->>'channel','isolated',route->>'merchant',session_user::name,session_user::name)
        AND meton_inbox.system_id()=route->>'inboxSystem' AND x.source_system<>meton_inbox.system_id() FOR SHARE OF x,a,p;
    IF r.controller IS NULL THEN RAISE EXCEPTION 'cash review controller retired' USING ERRCODE='42501'; END IF;
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
            ('meton_inbox.system_id()'::regprocedure,'meton_inbox.cash_manual_review_ready(jsonb)'::regprocedure,
             'meton_inbox.cash_manual_review_context(jsonb,text)'::regprocedure,
             'meton_inbox.cash_manual_review(jsonb,jsonb,text,bytea,text)'::regprocedure) AND has_function_privilege(session_user,p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'separate current cash review controller required' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION meton_inbox.cash_manual_review_ready(route jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN PERFORM meton_inbox.lock_cash_review_controller(route); RETURN true; END $$;

/** app 只从原绑定提取；人员请求不能以另一应用或商户的字段替换原案。 */
CREATE FUNCTION meton_inbox.cash_manual_review_route(route jsonb,p_key text) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE ref uuid;e jsonb;full_route jsonb;
BEGIN
    IF p_key IS NULL OR p_key !~ '^(refund|dispute)/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'exact original review key required' USING ERRCODE='22023'; END IF;
    ref:=split_part(p_key,'/',2)::uuid;
    IF ref='00000000-0000-0000-0000-000000000000'::uuid THEN RAISE EXCEPTION 'original review identity required' USING ERRCODE='22023'; END IF;
    IF split_part(p_key,'/',1)='refund' THEN SELECT envelope INTO e FROM meton_inbox.refund_aftercare_origins WHERE refund=ref;
    ELSE SELECT origin INTO e FROM meton_inbox.cash_dispute_cases WHERE id=ref; END IF;
    IF e IS NULL THEN RETURN NULL; END IF;
    IF (e#>>'{scope,deployment}',e#>>'{scope,source}',e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}') IS DISTINCT FROM
        (route->>'deployment',route->>'source',route->>'channel',route->>'cashEnvironment',route->>'merchant') THEN
        RAISE EXCEPTION 'original review scope differs' USING ERRCODE='42501'; END IF;
    full_route:=route||jsonb_build_object('app',e#>>'{scope,app}');
    PERFORM meton_inbox.require_refund_aftercare_reviewer(full_route);
    PERFORM meton_inbox.lock_original_cash(full_route,e#>>'{cash,order}',e#>>'{cash,transaction}');
    RETURN full_route;
END $$;

/** 人工依据包含原现金、原核验版本和原归档；刷新争议产生的新版本先提交，再由调用者重新读取。 */
CREATE FUNCTION meton_inbox.cash_manual_review_context(route jsonb,p_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE full_route jsonb;ref uuid;item jsonb;value jsonb;result jsonb;digest text;b meton_inbox.refund_aftercare_origins;
    v meton_inbox.refund_aftercare_results;c meton_inbox.cash_dispute_cases;
BEGIN
    PERFORM meton_inbox.lock_cash_review_controller(route);
    result:=jsonb_build_object('format',1,'state','original_unavailable','scope',route,'originalKey',p_key,
        'basisDigest',NULL,'value',NULL,'financialAuthority',false,'executionAuthorized',false);
    full_route:=meton_inbox.cash_manual_review_route(route,p_key);
    IF full_route IS NULL THEN RETURN result; END IF;
    ref:=split_part(p_key,'/',2)::uuid;
    IF split_part(p_key,'/',1)='refund' THEN
        SELECT * INTO b FROM meton_inbox.refund_aftercare_origins WHERE refund=ref;
        SELECT * INTO v FROM meton_inbox.refund_aftercare_results WHERE refund=ref ORDER BY revision DESC LIMIT 1;
        value:=jsonb_build_object('kind','refund','refund',ref,'app',full_route->>'app','order',b.envelope#>>'{cash,order}','transaction',b.envelope#>>'{cash,transaction}',
            'verificationRevision',v.revision,'verificationHash',encode(v.digest,'hex'),'payerState',v.verification->>'payerState',
            'channelState',v.verification->>'channelState','alreadyDecided',EXISTS(SELECT FROM meton_inbox.refund_alternative_decisions WHERE refund=ref));
    ELSE
        c:=meton_inbox.require_cash_dispute_review(full_route,ref);
        IF c.id IS NULL OR c.recorded_xid=pg_current_xact_id() THEN RETURN result||jsonb_build_object('state','original_pending'); END IF;
        value:=jsonb_build_object('kind','dispute','id',ref,'app',full_route->>'app','revision',c.revision,'state',c.state,'cashHash',encode(c.cash_hash,'hex'),
            'cashExposure',c.cash,'assigned',c.assigned_to IS NOT NULL,'finding',c.finding,'financialState','restricted');
    END IF;
    item:=meton_inbox.cash_archive_operations_snapshot(route,NULL,1,p_key)#>'{items,0}';
    IF item IS NULL THEN RETURN result; END IF;
    digest:=encode(sha256(convert_to(jsonb_build_array('meton.cash.manual-review.basis.v1',route,item->>'basisDigest',value)::text,'UTF8')),'hex');
    RETURN result||jsonb_build_object('state','observed','basisDigest',digest,'value',value);
END $$;

/** 原材料、原操作和首位审核人员同时落盘；结果未知只查询原回执，不补造新的批准或财务执行。 */
CREATE FUNCTION meton_inbox.cash_manual_review(route jsonb,q jsonb,key_reference text,evidence bytea,action text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE op uuid;ref uuid;key text:=q->>'originalKey';kind text:=q->>'reviewKind';facts jsonb:=q->'facts';
    saved meton_inbox.cash_review_receipts;request_hash bytea;context jsonb;full_route jsonb;state text;result jsonb;existing boolean;
BEGIN
    PERFORM meton_inbox.lock_cash_review_controller(route);
    IF action IS NULL OR action NOT IN ('record','result') OR jsonb_typeof(q) IS DISTINCT FROM 'object' OR
        (q ?& ARRAY['format','operation','originalKey','basisDigest','reviewKind','facts','person','personVersion','role','intentDigest','until']) IS NOT TRUE OR
        q-ARRAY['format','operation','originalKey','basisDigest','reviewKind','facts','person','personVersion','role','intentDigest','until']<>'{}'::jsonb OR
        (q->>'format'='1' AND q->>'operation'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND
         q->>'person'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND q->>'personVersion'~'^[1-9][0-9]{0,17}$' AND
         q->>'basisDigest'~'^[0-9a-f]{64}$' AND q->>'intentDigest'~'^[0-9a-f]{64}$' AND q->>'role'='reviewer' AND
         kind IN ('payer','alternative','dispute') AND jsonb_typeof(facts)='object' AND facts->>'materialHash'~'^[0-9a-f]{64}$' AND
         (q->>'until')::timestamptz>clock_timestamp() AND (q->>'until')::timestamptz<=clock_timestamp()+interval '30 seconds' AND
         octet_length(q::text)<=12288 AND octet_length(facts::text)<=8192) IS NOT TRUE THEN
        RAISE EXCEPTION 'bounded current personnel review required' USING ERRCODE='22023'; END IF;
    op:=(q->>'operation')::uuid;
    IF op='00000000-0000-0000-0000-000000000000'::uuid OR (q->>'person')::uuid='00000000-0000-0000-0000-000000000000'::uuid OR
        key IS NULL OR key !~ '^(refund|dispute)/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' OR
        (kind='dispute') IS DISTINCT FROM (split_part(key,'/',1)='dispute') THEN
        RAISE EXCEPTION 'original review command identity required' USING ERRCODE='22023'; END IF;
    ref:=split_part(key,'/',2)::uuid;
    IF ref='00000000-0000-0000-0000-000000000000'::uuid THEN RAISE EXCEPTION 'original review identity required' USING ERRCODE='22023'; END IF;
    request_hash:=sha256(convert_to(jsonb_build_array('meton.cash.manual-review.command.v1',route,
        q-ARRAY['person','personVersion','role','intentDigest','until'])::text,'UTF8'));
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.cash.manual-review.command.v1/'||jsonb_build_array(route->>'deployment',route->>'source',op)::text,0));
    IF (q->>'until')::timestamptz<=clock_timestamp() THEN RAISE EXCEPTION 'review authorization expired' USING ERRCODE='42501'; END IF;
    SELECT * INTO saved FROM meton_inbox.cash_review_receipts WHERE (deployment,source,operation)=(route->>'deployment',route->>'source',op);
    IF saved.operation IS NOT NULL THEN
        IF saved.scope IS DISTINCT FROM route OR saved.original_key IS DISTINCT FROM key OR saved.request_hash<>request_hash THEN
            RAISE EXCEPTION 'personnel review operation reused' USING ERRCODE='23505'; END IF;
        RETURN saved.receipt;
    END IF;
    result:=jsonb_build_object('format',1,'state','operation_unknown','scope',route,'operation',op,'originalKey',key,
        'basisDigest',q->>'basisDigest','reviewKind',kind,'financialAuthority',false,'executionAuthorized',false);
    IF action='result' THEN RETURN result; END IF;
    context:=meton_inbox.cash_manual_review_context(route,key);
    IF context->>'state'<>'observed' THEN state:=context->>'state';
    ELSIF context->>'basisDigest' IS DISTINCT FROM q->>'basisDigest' THEN state:='basis_changed';
    ELSE
        -- 旧裸审核没有本接缝的人员回执，不允许新服务把它认领成另一个人的新批准。
        existing:=CASE kind WHEN 'payer' THEN EXISTS(SELECT FROM meton_inbox.refund_payer_reviews WHERE (refund,operation)=(ref,op))
            WHEN 'alternative' THEN EXISTS(SELECT FROM meton_inbox.refund_alternative_approvals WHERE (refund,operation)=(ref,op))
            ELSE EXISTS(SELECT FROM meton_inbox.cash_dispute_actions WHERE (dispute,operation)=(ref,op)) END;
        IF existing THEN state:='original_operation_exists';
        ELSE
            IF key_reference IS NULL OR length(key_reference) NOT BETWEEN 1 AND 120 OR evidence IS NULL OR octet_length(evidence) NOT BETWEEN 29 AND 1572864 THEN
                RAISE EXCEPTION 'sealed original material required' USING ERRCODE='22023'; END IF;
            full_route:=meton_inbox.cash_manual_review_route(route,key);
            IF kind='payer' THEN state:=meton_inbox.record_original_payer_review(full_route,ref,op,facts,key_reference,evidence);
            ELSIF kind='alternative' THEN state:=meton_inbox.record_original_alternative_approval(full_route,ref,op,facts,key_reference,evidence);
            ELSE state:=meton_inbox.record_cash_dispute_review(full_route,ref,op,facts,key_reference,evidence); END IF;
        END IF;
    END IF;
    IF state IS NULL OR state NOT IN ('recorded','original_unavailable','original_pending','basis_changed','original_operation_exists') THEN
        RAISE EXCEPTION 'original review result unknown' USING ERRCODE='55000'; END IF;
    IF (q->>'until')::timestamptz<=clock_timestamp() THEN RAISE EXCEPTION 'review authorization expired' USING ERRCODE='42501'; END IF;
    result:=result||jsonb_build_object('state',state);
    INSERT INTO meton_inbox.cash_review_receipts(deployment,source,operation,scope,original_key,request_hash,actor,receipt,material_route,material_key_ref)
        VALUES(route->>'deployment',route->>'source',op,route,key,request_hash,
            jsonb_build_object('person',q->'person','version',q->'personVersion','role',q->'role','intentDigest',q->'intentDigest'),result,
            CASE WHEN state='recorded' THEN full_route::text END,CASE WHEN state='recorded' THEN key_reference END);
    RETURN result;
END $$;
REVOKE ALL ON FUNCTION meton_inbox.lock_cash_review_controller(jsonb),meton_inbox.cash_manual_review_ready(jsonb),
    meton_inbox.cash_manual_review_route(jsonb,text),meton_inbox.cash_manual_review_context(jsonb,text),
    meton_inbox.cash_manual_review(jsonb,jsonb,text,bytea,text) FROM PUBLIC;
