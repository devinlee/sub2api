-- 主动查询有自己的证据类型和内部引用。支付通知、退款通知和签名查单各保留原文，现金去重仍沿同一原交易。
ALTER TABLE meton_inbox.receipts DROP CONSTRAINT receipts_kind_check;
ALTER TABLE meton_inbox.receipts ADD CHECK(kind IN ('payment','refund','payment_query'));

-- 沿既有追加逻辑保存查单证明。两个公开入口各自锁住对应的独立角色，内部共用唯一插入和冲突留存逻辑。
DO $split$
DECLARE old text:=pg_get_functiondef('meton_inbox.accept_notice(jsonb,text,text,bytea,bytea,text,text,bytea)'::regprocedure);
    name_text constant text:='FUNCTION meton_inbox.accept_notice(';
    kind_guard constant text:='kind_name NOT IN (''payment'',''refund'')';
    role_guard constant text:='PERFORM meton_inbox.lock_current_writer(route);';
BEGIN
    IF cardinality(string_to_array(old,name_text))<>2 OR cardinality(string_to_array(old,kind_guard))<>2 OR cardinality(string_to_array(old,role_guard))<>2 THEN
        RAISE EXCEPTION 'original receipt schema changed'; END IF;
    EXECUTE replace(replace(replace(old,name_text,'FUNCTION meton_inbox.store_verified_proof('),kind_guard,
        'kind_name NOT IN (''payment'',''refund'',''payment_query'')'),role_guard,'');
END $split$;
REVOKE ALL ON FUNCTION meton_inbox.store_verified_proof(jsonb,text,text,bytea,bytea,text,text,bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION meton_inbox.accept_notice(route jsonb, kind_name text, delivery_id text, fact_hash bytea,
    signed_hash bytea, verifier text, key_ref text, evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF kind_name IS NULL OR kind_name NOT IN ('payment','refund') THEN RAISE EXCEPTION 'invalid notification kind' USING ERRCODE='22023'; END IF;
    PERFORM meton_inbox.lock_current_writer(route);
    RETURN meton_inbox.store_verified_proof(route,kind_name,delivery_id,fact_hash,signed_hash,verifier,key_ref,evidence);
END $$;
CREATE FUNCTION meton_inbox.accept_payment_query(route jsonb, proof_ref text, fact_hash bytea,
    signed_hash bytea, verifier text, key_ref text, evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF proof_ref IS NULL OR proof_ref !~ '^q-[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid original query reference' USING ERRCODE='22023'; END IF;
    PERFORM meton_inbox.lock_purchase_consumer(route);
    RETURN meton_inbox.store_verified_proof(route,'payment_query',proof_ref,fact_hash,signed_hash,verifier,key_ref,evidence);
END $$;

-- 使用与通知相同的票据、过期和完成逻辑。旧版通知处理器只领取通知，不能误领新增的查单证据。
DO $query_jobs$
DECLARE claim text:=pg_get_functiondef('meton_inbox.claim_purchase_notice(jsonb)'::regprocedure);
    material text:=pg_get_functiondef('meton_inbox.read_purchase_notice(jsonb,uuid,bytea,uuid)'::regprocedure);
    predicate constant text:='route->>''merchant'',''payment'')';
BEGIN
    IF cardinality(string_to_array(claim,predicate))<>2 OR cardinality(string_to_array(material,predicate))<>2 THEN
        RAISE EXCEPTION 'original purchase work predicates changed'; END IF;
    EXECUTE replace(replace(claim,'FUNCTION meton_inbox.claim_purchase_notice(','FUNCTION meton_inbox.claim_payment_query('),
        predicate,'route->>''merchant'',''payment_query'')');
    EXECUTE replace(replace(material,'FUNCTION meton_inbox.read_purchase_notice(','FUNCTION meton_inbox.read_payment_query('),
        predicate,'route->>''merchant'',''payment_query'')');
END $query_jobs$;
REVOKE ALL ON FUNCTION meton_inbox.accept_payment_query(jsonb,text,bytea,bytea,text,text,bytea),
    meton_inbox.claim_payment_query(jsonb),meton_inbox.read_payment_query(jsonb,uuid,bytea,uuid) FROM PUBLIC;
