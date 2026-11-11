-- 外部强制返还不受本地退款发送锁控制。复用独立收件库，永久保留每种已验事实，不把超退截成原本金。
ALTER TABLE meton_inbox.receipts DROP CONSTRAINT receipts_kind_check;
ALTER TABLE meton_inbox.receipts ADD CHECK(kind IN ('payment','refund','payment_query','external_return'));
DO $kind$
DECLARE body text:=pg_get_functiondef('meton_inbox.store_verified_proof(jsonb,text,text,bytea,bytea,text,text,bytea)'::regprocedure);
    anchor text:='kind_name NOT IN (''payment'',''refund'',''payment_query'')';
BEGIN
    IF cardinality(string_to_array(body,anchor))<>2 THEN RAISE EXCEPTION 'original proof kinds changed'; END IF;
    EXECUTE replace(body,anchor,'kind_name NOT IN (''payment'',''refund'',''payment_query'',''external_return'')');
END $kind$;

CREATE TABLE meton_inbox.external_cash_returns(
    receipt uuid NOT NULL, digest bytea NOT NULL, original bytea NOT NULL CHECK(octet_length(original)=32),
    economic_hash bytea NOT NULL CHECK(octet_length(economic_hash)=32), facts jsonb NOT NULL,
    PRIMARY KEY(receipt,digest), FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.proofs
);
CREATE INDEX external_cash_return_original ON meton_inbox.external_cash_returns(original,receipt);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.external_cash_returns
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.external_cash_returns ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_inbox.external_cash_returns FROM PUBLIC;

/** 只接受当前受限验真角色。真实签名原文在既有 proofs 中加密保存，普通会员和裁决角色不能声明资金已退。 */
CREATE FUNCTION meton_inbox.accept_external_cash_return(route jsonb,facts jsonb,signed_hash bytea,verifier text,key_ref text,evidence bytea)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE original_key bytea; fact_hash bytea; economic bytea; id uuid; stored text; report jsonb;
BEGIN
    PERFORM meton_inbox.lock_current_writer(route);
    IF current_setting('transaction_isolation')<>'read committed' OR current_setting('session_replication_role')<>'origin'
        OR pg_has_role(session_user,current_user,'MEMBER') OR has_schema_privilege(session_user,'meton_inbox','CREATE')
        OR EXISTS(SELECT FROM pg_roles r WHERE (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)
            AND pg_has_role(session_user,r.oid,'MEMBER'))
        OR EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p')
            AND (has_any_column_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE') OR has_table_privilege(session_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) THEN
        RAISE EXCEPTION 'restricted external cash verifier required' USING ERRCODE='42501'; END IF;
    IF (jsonb_typeof(facts)='object' AND facts->'format'='1'::jsonb
        AND facts-ARRAY['format','kind','reference','order','transaction','currency','returnedFen','occurredAt']='{}'::jsonb
        AND facts->>'kind' IN ('chargeback','reversal') AND facts->>'reference'~'^[A-Za-z0-9_.:-]{1,128}$'
        AND length(facts->>'order') BETWEEN 1 AND 64 AND length(facts->>'transaction') BETWEEN 1 AND 64
        AND facts->>'currency'~'^[A-Z]{3}$' AND jsonb_typeof(facts->'returnedFen')='string'
        AND facts->>'returnedFen'~'^[1-9][0-9]{0,17}$'
        AND isfinite((facts->>'occurredAt')::timestamptz)) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid verified external return' USING ERRCODE='22023'; END IF;
    original_key:=meton_inbox.lock_original_cash(route,facts->>'order',facts->>'transaction');
    -- 不把代次、处理节点、通知投递号或冲正/拒付类型加入经济事件身份。同一渠道返还编号不会因换写者而多记一笔。
    report:=jsonb_build_object('app',route->>'app','facts',facts);
    fact_hash:=sha256(convert_to(report::text,'UTF8'));
    economic:=sha256(convert_to(jsonb_build_object('original',encode(original_key,'hex'),'facts',facts-'occurredAt')::text,'UTF8'));
    stored:=meton_inbox.store_verified_proof(route,'external_return',facts->>'reference',fact_hash,signed_hash,verifier,key_ref,evidence);
    SELECT receipt INTO STRICT id FROM meton_inbox.receipts WHERE (channel,cash_environment,merchant,kind,delivery)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant','external_return',facts->>'reference');
    INSERT INTO meton_inbox.external_cash_returns VALUES(id,fact_hash,original_key,economic,facts) ON CONFLICT DO NOTHING;
    -- 同一返还号指向不同交易或金额时，所有版本均保留；不把“先到”当成最终真实金额。
    RETURN CASE WHEN (SELECT count(DISTINCT economic_hash) FROM meton_inbox.external_cash_returns WHERE receipt=id)>1
        THEN 'review' ELSE 'accepted' END;
END $$;

/** 返回同一原交易的已知返还与冲突数量；金额冲突不任选一个金额对平，原证明仍可逐份取回。 */
CREATE FUNCTION meton_inbox.external_cash_return_summary(original_key bytea,currency_code text) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    WITH related AS (
        SELECT DISTINCT receipt FROM meton_inbox.external_cash_returns WHERE original=original_key
    ), originals AS (
        SELECT e.receipt,count(DISTINCT e.economic_hash) variants,
            bool_and(e.original=original_key AND e.facts->>'currency'=currency_code) same_original,
            max((e.facts->>'returnedFen')::numeric) amount
        FROM related r JOIN meton_inbox.external_cash_returns e USING(receipt) GROUP BY e.receipt
    )
    SELECT jsonb_build_object('events',count(*),'confirmedFen',
        coalesce(sum(amount) FILTER(WHERE variants=1 AND same_original),0)::text,
        'ambiguousEvents',count(*) FILTER(WHERE variants<>1 OR NOT same_original))
    FROM originals
$$;

/** 当前受限核对角色可读原交易概要。拿到概要不会获得退款或修改额度的权限。 */
CREATE FUNCTION meton_inbox.read_external_cash_returns(route jsonb,trade text,txn text,currency_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE original_key bytea;
BEGIN
    PERFORM meton_inbox.require_refund_resolver(route);
    IF (currency_code~'^[A-Z]{3}$') IS NOT TRUE THEN RAISE EXCEPTION 'invalid currency' USING ERRCODE='22023'; END IF;
    original_key:=meton_inbox.lock_original_cash(route,trade,txn);
    RETURN meton_inbox.external_cash_return_summary(original_key,currency_code);
END $$;

-- 在原交易锁内先看截点外事实。已知强制返还进入受限核对，旧来源快照不能重新发退款或补发购买额度。
DO $guards$
DECLARE wire text:=pg_get_functiondef('meton_inbox.original_refund_wire_risk(jsonb)'::regprocedure);
    purchase text:=pg_get_functiondef('meton_inbox.original_refund_proof(jsonb,text,text)'::regprocedure);
    wire_anchor text:='original_trade:=meton_inbox.lock_original_cash(s,k->>''order'',k->>''transaction'');';
    purchase_anchor text:='identity:=meton_inbox.lock_original_cash(route,trade,txn);';
BEGIN
    IF cardinality(string_to_array(wire,wire_anchor))<>2 OR cardinality(string_to_array(purchase,purchase_anchor))<>2 THEN
        RAISE EXCEPTION 'original cash guards changed'; END IF;
    EXECUTE replace(wire,wire_anchor,wire_anchor||'
    IF EXISTS(SELECT FROM meton_inbox.external_cash_returns WHERE original=original_trade) THEN RETURN ''external_return''; END IF;');
    EXECUTE replace(purchase,purchase_anchor,purchase_anchor||'
    IF EXISTS(SELECT FROM meton_inbox.external_cash_returns WHERE original=identity) THEN
        RETURN QUERY SELECT ''external_return''::text,NULL::text,NULL::text,NULL::bytea,NULL::bytea;
        RETURN;
    END IF;');
END $guards$;
REVOKE ALL ON FUNCTION meton_inbox.accept_external_cash_return(jsonb,jsonb,bytea,text,text,bytea),
    meton_inbox.external_cash_return_summary(bytea,text),meton_inbox.read_external_cash_returns(jsonb,text,text,text) FROM PUBLIC;
