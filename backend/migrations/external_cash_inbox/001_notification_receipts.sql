-- 由 sub2api 维护，单独安装在原订单库还原范围之外。此目录不参加普通来源迁移。
CREATE SCHEMA meton_inbox;
REVOKE ALL ON SCHEMA meton_inbox FROM PUBLIC;
CREATE FUNCTION meton_inbox.system_id() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT system_identifier::text FROM pg_catalog.pg_control_system()
$$;

-- 恢复时由运维切换写者和代次，应用角色没有修改授权。收件身份跨写者、验签密钥和来源恢复代次保持稳定。
CREATE TABLE meton_inbox.writers(
    channel text NOT NULL, cash_environment text NOT NULL, merchant text NOT NULL, app text NOT NULL,
    deployment text NOT NULL, source_name text NOT NULL, generation bigint NOT NULL CHECK(generation>0),
    source_system text NOT NULL CHECK(source_system ~ '^[0-9]{1,20}$'), writer name NOT NULL,
    PRIMARY KEY(channel,cash_environment,merchant,app)
);
CREATE TABLE meton_inbox.receipts(
    receipt uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    channel text NOT NULL, cash_environment text NOT NULL, merchant text NOT NULL,
    kind text NOT NULL CHECK(kind IN ('payment','refund')), delivery text NOT NULL CHECK(length(delivery) BETWEEN 1 AND 128),
    first_seen timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(channel,cash_environment,merchant,kind,delivery)
);
-- 每种受验事实最多留一份原签名材料。只保存加密包，表内的摘要用于比对，不能授权加款。
CREATE TABLE meton_inbox.proofs(
    receipt uuid NOT NULL REFERENCES meton_inbox.receipts, digest bytea NOT NULL CHECK(octet_length(digest)=32),
    channel_digest bytea NOT NULL CHECK(octet_length(channel_digest)=32),
    first_proof boolean NOT NULL, signature_key text NOT NULL CHECK(length(signature_key) BETWEEN 1 AND 128),
    recovery_key text NOT NULL CHECK(length(recovery_key) BETWEEN 1 AND 120),
    sealed bytea NOT NULL CHECK(octet_length(sealed) BETWEEN 29 AND 1572864),
    saved_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(receipt,digest)
);
CREATE UNIQUE INDEX notification_original_proof ON meton_inbox.proofs(receipt) WHERE first_proof;

CREATE FUNCTION meton_inbox.lock_current_writer(route jsonb) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
        OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') OR pg_is_in_recovery() THEN
        RAISE EXCEPTION 'durable notification store unavailable' USING ERRCODE='55000';
    END IF;
    -- 在同一事务内锁住外部写权，过代、错商户和与原库同集群均不能确认收件。
    PERFORM FROM meton_inbox.writers w WHERE
        (w.channel,w.cash_environment,w.merchant,w.app,w.deployment,w.source_name,w.generation,w.source_system,w.writer)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',route->>'deployment',
         route->>'source',(route->>'epoch')::bigint,route->>'sourceSystem',session_user)
        AND w.source_system<>meton_inbox.system_id() AND meton_inbox.system_id()=route->>'inboxSystem' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'notification writer not current' USING ERRCODE='42501'; END IF;
END $$;

-- 原库回退而通知已有确定收件时，只比较本次重新验真的渠道内容，不能由此认领新账号或补做履约。
CREATE FUNCTION meton_inbox.previously_received(route jsonb, kind_name text, delivery_id text, signed_hash bytea) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_current_writer(route);
    RETURN EXISTS(SELECT FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt) WHERE
        (r.channel,r.cash_environment,r.merchant,r.kind,r.delivery)=(route->>'channel',route->>'cashEnvironment',
        route->>'merchant',kind_name,delivery_id) AND p.first_proof AND p.channel_digest=signed_hash);
END $$;

CREATE FUNCTION meton_inbox.accept_notice(route jsonb, kind_name text, delivery_id text, fact_hash bytea,
    signed_hash bytea, verifier text, key_ref text, evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE id uuid; first_hash bytea; first_seen boolean;
BEGIN
    IF num_nulls(route,kind_name,delivery_id,fact_hash,signed_hash,verifier,key_ref,evidence)>0 OR
        kind_name NOT IN ('payment','refund') OR length(delivery_id) NOT BETWEEN 1 AND 128 OR
        octet_length(fact_hash)<>32 OR octet_length(signed_hash)<>32 OR length(verifier) NOT BETWEEN 1 AND 128 OR length(key_ref) NOT BETWEEN 1 AND 120 OR
        octet_length(evidence) NOT BETWEEN 29 AND 1572864 THEN
        RAISE EXCEPTION 'incomplete verified receipt' USING ERRCODE='22023';
    END IF;
    PERFORM meton_inbox.lock_current_writer(route);
    INSERT INTO meton_inbox.receipts(channel,cash_environment,merchant,kind,delivery)
        VALUES(route->>'channel',route->>'cashEnvironment',route->>'merchant',kind_name,delivery_id)
        ON CONFLICT(channel,cash_environment,merchant,kind,delivery) DO NOTHING RETURNING receipt INTO id;
    first_seen:=FOUND;
    IF NOT first_seen THEN
        SELECT receipt INTO STRICT id FROM meton_inbox.receipts WHERE (channel,cash_environment,merchant,kind,delivery)=
            (route->>'channel',route->>'cashEnvironment',route->>'merchant',kind_name,delivery_id) FOR UPDATE;
        SELECT digest INTO STRICT first_hash FROM meton_inbox.proofs WHERE receipt=id AND first_proof;
    END IF;
    INSERT INTO meton_inbox.proofs(receipt,digest,channel_digest,first_proof,signature_key,recovery_key,sealed)
        VALUES(id,fact_hash,signed_hash,first_seen,verifier,key_ref,evidence) ON CONFLICT(receipt,digest) DO NOTHING;
    IF NOT first_seen AND first_hash<>fact_hash THEN RETURN 'conflict'; END IF;
    RETURN 'accepted';
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA meton_inbox FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA meton_inbox FROM PUBLIC;
