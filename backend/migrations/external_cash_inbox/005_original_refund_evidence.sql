-- 索引只定位加密证明。渠道回调仍然只有独立库追加权；原账号和实际业务效果由来源端重新核对。
CREATE TABLE meton_inbox.refund_evidence(
    original bytea NOT NULL CHECK(octet_length(original)=32),
    receipt uuid NOT NULL, digest bytea NOT NULL, canonical bytea NOT NULL CHECK(octet_length(canonical)=32),
    PRIMARY KEY(receipt,digest), FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.proofs
);
CREATE INDEX original_refund_proofs ON meton_inbox.refund_evidence(original,receipt,digest);
CREATE TABLE meton_inbox.unindexed_refunds(
    channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,receipt uuid NOT NULL,digest bytea NOT NULL,
    PRIMARY KEY(channel,cash_environment,merchant,receipt,digest),FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.proofs
);
-- 迁移与旧写者互斥。先建立索引待办，切换后只有新的受控退款入口可以追加。
LOCK TABLE meton_inbox.receipts,meton_inbox.proofs IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO meton_inbox.unindexed_refunds SELECT r.channel,r.cash_environment,r.merchant,r.receipt,p.digest
    FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt) WHERE r.kind='refund';
REVOKE ALL ON meton_inbox.refund_evidence,meton_inbox.unindexed_refunds FROM PUBLIC;

CREATE FUNCTION meton_inbox.lock_original_cash(route jsonb,trade text,txn text) RETURNS bytea
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE identity text;
BEGIN
    IF (length(trade) BETWEEN 1 AND 64 AND length(txn) BETWEEN 1 AND 64) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid original transaction' USING ERRCODE='22023'; END IF;
    identity:=jsonb_build_array(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',trade,txn)::text;
    PERFORM pg_advisory_xact_lock(hashtextextended(identity,0));
    RETURN sha256(convert_to(identity,'UTF8'));
END $$;

-- 历史退款的密文可能还带已经绑定的本地退款号；只有完整旧摘要和已验渠道字段均相符才认领原证明。
CREATE FUNCTION meton_inbox.accept_refund_notice(route jsonb,delivery_id text,trade text,txn text,fact_hash bytea,legacy_hash bytea,
    signed_hash bytea,verifier text,key_ref text,evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE identity bytea; id uuid; stored bytea; result text;
BEGIN
    PERFORM meton_inbox.lock_current_writer(route);
    identity:=meton_inbox.lock_original_cash(route,trade,txn);
    SELECT r.receipt,p.digest INTO id,stored FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt)
        LEFT JOIN meton_inbox.refund_evidence i ON (i.receipt,i.digest)=(p.receipt,p.digest)
        WHERE (r.channel,r.cash_environment,r.merchant,r.kind,r.delivery)=(route->>'channel',route->>'cashEnvironment',route->>'merchant','refund',delivery_id)
        AND p.first_proof AND p.channel_digest=signed_hash AND ((i.original=identity AND i.canonical=fact_hash)
            OR (i.receipt IS NULL AND p.digest=legacy_hash));
    IF FOUND THEN result:='accepted';
    ELSE
        result:=meton_inbox.store_verified_proof(route,'refund',delivery_id,fact_hash,signed_hash,verifier,key_ref,evidence);
        SELECT r.receipt INTO STRICT id FROM meton_inbox.receipts r WHERE
            (r.channel,r.cash_environment,r.merchant,r.kind,r.delivery)=(route->>'channel',route->>'cashEnvironment',route->>'merchant','refund',delivery_id);
        stored:=fact_hash;
    END IF;
    INSERT INTO meton_inbox.refund_evidence VALUES(identity,id,stored,fact_hash) ON CONFLICT DO NOTHING;
    DELETE FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant,u.receipt,u.digest)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',id,stored);
    RETURN result;
END $$;
CREATE OR REPLACE FUNCTION meton_inbox.accept_notice(route jsonb,kind_name text,delivery_id text,fact_hash bytea,
    signed_hash bytea,verifier text,key_ref text,evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF kind_name IS DISTINCT FROM 'payment' THEN RAISE EXCEPTION 'indexed refund proof required' USING ERRCODE='22023'; END IF;
    PERFORM meton_inbox.lock_current_writer(route);
    RETURN meton_inbox.store_verified_proof(route,kind_name,delivery_id,fact_hash,signed_hash,verifier,key_ref,evidence);
END $$;

-- 即使来源刚恢复到旧截点，也先从截点外查证，再在同一把原交易锁内完成本次交接。
CREATE FUNCTION meton_inbox.original_refund_proof(route jsonb,trade text,txn text)
RETURNS TABLE(state text,delivery text,key_ref text,digest bytea,sealed bytea)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE identity bytea;
BEGIN
    PERFORM meton_inbox.lock_purchase_consumer(route);
    identity:=meton_inbox.lock_original_cash(route,trade,txn);
    -- 旧版证明只含密文，无法从投递号推断所属交易。原消费者在下一次重试前先验签补索引。
    IF EXISTS(SELECT FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant')) THEN
        RETURN QUERY SELECT 'pending_legacy'::text,NULL::text,NULL::text,NULL::bytea,NULL::bytea;
        RETURN;
    END IF;
    RETURN QUERY SELECT 'observed'::text,r.delivery,p.recovery_key,p.digest,p.sealed FROM meton_inbox.refund_evidence i
        JOIN meton_inbox.proofs p ON (i.receipt,i.digest)=(p.receipt,p.digest) JOIN meton_inbox.receipts r ON r.receipt=i.receipt
        WHERE i.original=identity ORDER BY i.receipt,i.digest LIMIT 1;
    IF NOT FOUND THEN RETURN QUERY SELECT 'clear'::text,NULL::text,NULL::text,NULL::bytea,NULL::bytea; END IF;
END $$;

-- 沿用既有租约和重试。退款观察到达时即可在原账号形成待核对事项，不依赖用户再次打开订单或收到付款。
DO $lane$
DECLARE claim text:=pg_get_functiondef('meton_inbox.claim_purchase_notice(jsonb)'::regprocedure);
    material text:=pg_get_functiondef('meton_inbox.read_purchase_notice(jsonb,uuid,bytea,uuid)'::regprocedure);
    predicate constant text:='route->>''merchant'',''payment'')';
BEGIN
    IF cardinality(string_to_array(claim,predicate))<>2 OR cardinality(string_to_array(material,predicate))<>2 THEN
        RAISE EXCEPTION 'purchase worker evidence changed'; END IF;
    EXECUTE replace(replace(claim,'FUNCTION meton_inbox.claim_purchase_notice(','FUNCTION meton_inbox.claim_refund_notice('),
        predicate,'route->>''merchant'',''refund'')');
    EXECUTE replace(replace(material,'FUNCTION meton_inbox.read_purchase_notice(','FUNCTION meton_inbox.read_refund_notice('),
        predicate,'route->>''merchant'',''refund'')');
END $lane$;

CREATE FUNCTION meton_inbox.index_original_refund(route jsonb,id uuid,hash bytea,lease uuid,trade text,txn text,canonical_hash bytea)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE identity bytea;
BEGIN
    PERFORM FROM meton_inbox.read_refund_notice(route,id,hash,lease);
    IF NOT FOUND THEN RAISE EXCEPTION 'refund lease changed' USING ERRCODE='55000'; END IF;
    identity:=meton_inbox.lock_original_cash(route,trade,txn);
    INSERT INTO meton_inbox.refund_evidence VALUES(identity,id,hash,canonical_hash) ON CONFLICT DO NOTHING;
    IF NOT EXISTS(SELECT FROM meton_inbox.refund_evidence i WHERE
        (i.receipt,i.digest,i.original,i.canonical)=(id,hash,identity,canonical_hash)) THEN
        RAISE EXCEPTION 'refund index differs' USING ERRCODE='22023'; END IF;
    DELETE FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant,u.receipt,u.digest)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',id,hash);
END $$;
REVOKE ALL ON FUNCTION meton_inbox.lock_original_cash(jsonb,text,text),meton_inbox.original_refund_proof(jsonb,text,text),
    meton_inbox.accept_refund_notice(jsonb,text,text,text,bytea,bytea,bytea,text,text,bytea),meton_inbox.claim_refund_notice(jsonb),
    meton_inbox.read_refund_notice(jsonb,uuid,bytea,uuid),meton_inbox.index_original_refund(jsonb,uuid,bytea,uuid,text,text,bytea) FROM PUBLIC;
