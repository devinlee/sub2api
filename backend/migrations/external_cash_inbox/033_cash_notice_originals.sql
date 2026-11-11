-- 原凭证关联由独立索引身份建立，不复用运营读者、收件写者或资金消费者的权限。
CREATE TABLE meton_inbox.cash_notice_indexers(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),source_system text NOT NULL,
    channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,app text NOT NULL,indexer name NOT NULL UNIQUE,
    PRIMARY KEY(deployment,source,epoch,channel,cash_environment,merchant,app)
);
CREATE TABLE meton_inbox.cash_notice_origin_jobs(
    receipt uuid NOT NULL,digest bytea NOT NULL,deployment text NOT NULL,source text NOT NULL,app text NOT NULL,
    epoch bigint NOT NULL CHECK(epoch>0),token uuid NOT NULL,state text NOT NULL CHECK(state IN ('claimed','retry','indexed','review','foreign')),
    available_at timestamptz NOT NULL,reason text NOT NULL,
    PRIMARY KEY(receipt,digest,deployment,source,app),FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.proofs
);
CREATE TABLE meton_inbox.cash_notice_originals(
    receipt uuid NOT NULL,digest bytea NOT NULL,deployment text NOT NULL,source text NOT NULL,app text NOT NULL,
    source_system text NOT NULL,origin jsonb NOT NULL,notice jsonb NOT NULL,
    PRIMARY KEY(receipt,digest,deployment,source,app),FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.proofs,
    CHECK(jsonb_typeof(origin)='object' AND jsonb_typeof(notice)='object')
);
CREATE TRIGGER immutable_notice_indexer BEFORE UPDATE OR DELETE ON meton_inbox.cash_notice_indexers
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
CREATE TRIGGER immutable_notice_original BEFORE UPDATE OR DELETE ON meton_inbox.cash_notice_originals
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.cash_notice_indexers ENABLE ALWAYS TRIGGER immutable_notice_indexer;
ALTER TABLE meton_inbox.cash_notice_originals ENABLE ALWAYS TRIGGER immutable_notice_original;
REVOKE ALL ON meton_inbox.cash_notice_indexers,meton_inbox.cash_notice_origin_jobs,meton_inbox.cash_notice_originals FROM PUBLIC;

CREATE FUNCTION meton_inbox.lock_cash_notice_indexer(route jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF current_setting('transaction_read_only')<>'off' OR current_setting('transaction_isolation')<>'read committed' OR
        pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR current_setting('fsync')<>'on' OR
        current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') THEN
        RAISE EXCEPTION 'current durable notice index required' USING ERRCODE='25006'; END IF;
    PERFORM FROM meton_inbox.cash_notice_indexers i JOIN meton_inbox.writers w ON
        (w.deployment,w.source_name,w.generation,w.source_system,w.channel,w.cash_environment,w.merchant,w.app)=
        (i.deployment,i.source,i.epoch,i.source_system,i.channel,i.cash_environment,i.merchant,i.app)
        WHERE (i.deployment,i.source,i.epoch,i.source_system,i.channel,i.cash_environment,i.merchant,i.app,i.indexer)=
            (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'sourceSystem',route->>'channel',
             route->>'cashEnvironment',route->>'merchant',route->>'app',session_user::name)
        AND i.source_system<>meton_inbox.system_id() AND route->>'inboxSystem'=meton_inbox.system_id()
        AND i.indexer<>w.writer FOR SHARE OF i,w;
    IF NOT FOUND THEN RAISE EXCEPTION 'notice indexer retired' USING ERRCODE='42501'; END IF;
    IF EXISTS(SELECT FROM pg_roles p WHERE p.rolname=session_user AND (p.rolsuper OR p.rolinherit OR p.rolcreatedb OR p.rolcreaterole OR p.rolreplication OR p.rolbypassrls)) OR
        EXISTS(SELECT FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=session_user)) OR
        has_schema_privilege(session_user,'meton_inbox','CREATE') OR
        EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
            (has_table_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) OR
        EXISTS(SELECT FROM pg_proc p WHERE p.pronamespace='meton_inbox'::regnamespace AND p.oid NOT IN
            ('meton_inbox.system_id()'::regprocedure,'meton_inbox.lock_cash_notice_indexer(jsonb)'::regprocedure,
             'meton_inbox.claim_cash_notice_origin(jsonb)'::regprocedure,'meton_inbox.read_cash_notice_origin(jsonb,uuid,bytea,uuid)'::regprocedure,
             'meton_inbox.finish_cash_notice_origin(jsonb,uuid,bytea,uuid,text,text,bytea)'::regprocedure) AND has_function_privilege(session_user,p.oid,'EXECUTE')) THEN
        RAISE EXCEPTION 'separate notice index authority required' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION meton_inbox.claim_cash_notice_origin(route jsonb)
RETURNS TABLE(receipt_id uuid,proof_hash bytea,lease uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_cash_notice_indexer(route);
    RETURN QUERY WITH picked AS (
        SELECT p.receipt,p.digest FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt)
        LEFT JOIN meton_inbox.cash_notice_origin_jobs j ON (j.receipt,j.digest,j.deployment,j.source,j.app)=
            (p.receipt,p.digest,route->>'deployment',route->>'source',route->>'app')
        WHERE (r.channel,r.cash_environment,r.merchant)=(route->>'channel',route->>'cashEnvironment',route->>'merchant')
            AND r.kind IN ('payment','refund','payment_query') AND
            (j.receipt IS NULL OR (j.state IN ('claimed','retry') AND j.available_at<=clock_timestamp()))
        ORDER BY p.saved_at,p.receipt,p.digest LIMIT 1 FOR UPDATE OF p SKIP LOCKED)
    INSERT INTO meton_inbox.cash_notice_origin_jobs AS j(receipt,digest,deployment,source,app,epoch,token,state,available_at,reason)
        SELECT receipt,digest,route->>'deployment',route->>'source',route->>'app',(route->>'epoch')::bigint,
            gen_random_uuid(),'claimed',clock_timestamp()+interval '30 seconds','' FROM picked
        ON CONFLICT(receipt,digest,deployment,source,app) DO UPDATE SET epoch=excluded.epoch,token=excluded.token,state='claimed',
            available_at=excluded.available_at,reason='' WHERE j.state IN ('claimed','retry') AND j.available_at<=clock_timestamp()
        RETURNING j.receipt,j.digest,j.token;
END $$;

CREATE FUNCTION meton_inbox.read_cash_notice_origin(route jsonb,original uuid,hash bytea,lease uuid)
RETURNS TABLE(kind text,delivery text,key_ref text,sealed bytea)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_cash_notice_indexer(route);
    PERFORM FROM meton_inbox.cash_notice_origin_jobs j WHERE
        (j.receipt,j.digest,j.deployment,j.source,j.app,j.epoch,j.token,j.state)=
        (original,hash,route->>'deployment',route->>'source',route->>'app',(route->>'epoch')::bigint,lease,'claimed')
        AND j.available_at>clock_timestamp() FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'obsolete notice index lease' USING ERRCODE='55000'; END IF;
    RETURN QUERY SELECT r.kind,r.delivery,p.recovery_key,p.sealed FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt)
        WHERE (r.receipt,p.digest,r.channel,r.cash_environment,r.merchant)=
            (original,hash,route->>'channel',route->>'cashEnvironment',route->>'merchant');
END $$;

-- 原规范字节必须与已保存的证明摘要相同。只存查找需要的账号引用和经济字段，不存原文、签名或恢复秘密。
CREATE FUNCTION meton_inbox.finish_cash_notice_origin(route jsonb,original uuid,hash bytea,lease uuid,result text,reason_code text,canonical bytea)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r meton_inbox.receipts; b jsonb; o jsonb; n jsonb;
    base_fields text[]:=ARRAY['version','account','user','creation','sourceMarker','intent','order','paramsHash','channel','cashEnvironment','merchant','app',
        'currency','priceFen','priceVersion','creditUnits','unit','unitsPerYuan'];
BEGIN
    PERFORM meton_inbox.lock_cash_notice_indexer(route);
    IF result IS NULL OR result NOT IN ('retry','indexed','review','foreign') OR reason_code IS NULL OR reason_code !~ '^[a-z_]{1,48}$' THEN
        RAISE EXCEPTION 'bounded notice index result required' USING ERRCODE='22023'; END IF;
    PERFORM FROM meton_inbox.cash_notice_origin_jobs j WHERE
        (j.receipt,j.digest,j.deployment,j.source,j.app,j.epoch,j.token,j.state)=
        (original,hash,route->>'deployment',route->>'source',route->>'app',(route->>'epoch')::bigint,lease,'claimed')
        AND j.available_at>clock_timestamp() FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    IF result='indexed' THEN
        IF canonical IS NULL OR octet_length(canonical) NOT BETWEEN 2 AND 32768 OR sha256(canonical)<>hash THEN
            RAISE EXCEPTION 'original canonical proof required' USING ERRCODE='42501'; END IF;
        SELECT * INTO STRICT r FROM meton_inbox.receipts WHERE receipt=original;
        b:=convert_from(canonical,'UTF8')::jsonb; o:=b->'origin'; n:=b->'notice';
        IF (jsonb_typeof(b)='object' AND b-ARRAY['origin','notice']='{}'::jsonb AND jsonb_typeof(o)='object' AND jsonb_typeof(n)='object'
            AND o ?& base_fields AND o->>'version'='1'
            AND o-(base_fields||ARRAY['payment','part','refund','refundIntent','refundOrder','basis','requestedFen','requestedUnits'])='{}'::jsonb
            AND n-ARRAY['delivery','kind','state','merchant','app','order','transaction','total','payerTotal','currency','payerCurrency','occurredAt',
                'refundOrder','refundID','refundFen','payerRefund']='{}'::jsonb
            AND (o->>'channel',o->>'cashEnvironment',o->>'merchant',o->>'app')=
                (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
            AND n->>'merchant'=o->>'merchant' AND n->>'order'=o->>'order'
            AND (CASE WHEN r.kind='payment_query' THEN n->>'kind'='payment' AND n->>'delivery'=''
                ELSE n->>'kind'=r.kind AND n->>'delivery'=r.delivery END)) IS NOT TRUE THEN
            RAISE EXCEPTION 'notice original scope differs' USING ERRCODE='42501'; END IF;
        o:=o-ARRAY['payment','part','refund','refundIntent','refundOrder','basis','requestedFen','requestedUnits'];
        INSERT INTO meton_inbox.cash_notice_originals VALUES(original,hash,route->>'deployment',route->>'source',route->>'app',route->>'sourceSystem',o,n)
            ON CONFLICT DO NOTHING;
        IF NOT EXISTS(SELECT FROM meton_inbox.cash_notice_originals i WHERE
            (i.receipt,i.digest,i.deployment,i.source,i.app,i.source_system,i.origin,i.notice)=
            (original,hash,route->>'deployment',route->>'source',route->>'app',route->>'sourceSystem',o,n)) THEN
            RAISE EXCEPTION 'notice original binding changed' USING ERRCODE='23505'; END IF;
    ELSIF canonical IS NOT NULL THEN
        RAISE EXCEPTION 'unexpected unverified notice bytes' USING ERRCODE='22023';
    END IF;
    UPDATE meton_inbox.cash_notice_origin_jobs j SET state=result,reason=reason_code,available_at=clock_timestamp()+interval '15 seconds'
        WHERE (j.receipt,j.digest,j.deployment,j.source,j.app)=(original,hash,route->>'deployment',route->>'source',route->>'app');
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION meton_inbox.lock_cash_notice_indexer(jsonb),meton_inbox.claim_cash_notice_origin(jsonb),
    meton_inbox.read_cash_notice_origin(jsonb,uuid,bytea,uuid),meton_inbox.finish_cash_notice_origin(jsonb,uuid,bytea,uuid,text,text,bytea) FROM PUBLIC;

-- 读取者只取得已经验真的原索引。索引和投递进度分别存在，posted 本身仍不构成原归属或结清。
DO $notice_link$
DECLARE body text:=pg_get_functiondef('meton_inbox.read_cash_archive_link(jsonb,text)'::regprocedure);
    point text:='WHEN ''refund'' THEN';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'archive original link changed'; END IF;
    EXECUTE replace(body,point,$branch$
        WHEN 'proof' THEN
            SELECT CASE WHEN count(*)=1 THEN jsonb_agg(jsonb_build_object('kind','notice','noticeKind',n.kind,'origin',i.origin,'notice',i.notice))->0 END
                INTO link FROM meton_inbox.cash_notice_originals i JOIN meton_inbox.receipts n USING(receipt)
                JOIN meton_inbox.writers w ON (w.deployment,w.source_name,w.generation,w.source_system,w.channel,w.cash_environment,w.merchant,w.app)=
                    (r.deployment,r.source,r.epoch,r.source_system,r.channel,r.cash_environment,r.merchant,i.app)
                WHERE i.receipt=(item#>>'{value,receipt}')::uuid AND encode(i.digest,'hex')=item#>>'{value,proof}'
                    AND (i.deployment,i.source,i.source_system)=(r.deployment,r.source,r.source_system);
        $branch$||point);
END $notice_link$;
