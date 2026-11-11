-- 保留在来源库恢复范围外。付款渠道和商户原单号决定唯一外发资格，重新签名和写入代次均不产生第二次资格。
CREATE TABLE meton_inbox.order_stop_proofs(
    channel text NOT NULL, cash_environment text NOT NULL, merchant text NOT NULL, trade text NOT NULL,
    intent uuid NOT NULL, marker uuid NOT NULL, params_hash text NOT NULL, outcome text NOT NULL,
    digest bytea NOT NULL CHECK(octet_length(digest)=32), verifier text NOT NULL, key_ref text NOT NULL, sealed bytea NOT NULL,
    saved_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(channel,cash_environment,merchant,trade,digest)
);
CREATE TABLE meton_inbox.order_close_tickets(
    channel text NOT NULL, cash_environment text NOT NULL, merchant text NOT NULL, trade text NOT NULL,
    intent uuid NOT NULL, marker uuid NOT NULL, params_hash text NOT NULL, dispatch uuid NOT NULL UNIQUE,
    proof_hash bytea NOT NULL, saved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(channel,cash_environment,merchant,trade), FOREIGN KEY(channel,cash_environment,merchant,trade,proof_hash)
        REFERENCES meton_inbox.order_stop_proofs(channel,cash_environment,merchant,trade,digest)
);
CREATE FUNCTION meton_inbox.record_order_stop_proof(route jsonb,original uuid,owner_marker uuid,original_trade text,
    original_params text,observed text,proof_hash bytea,serial text,secret_ref text,sealed_proof bytea)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_purchase_consumer(route);
    IF num_nulls(original,owner_marker,original_trade,original_params,observed,proof_hash,serial,secret_ref,sealed_proof)>0
        OR original_trade !~ '^[0-9a-f]{32}$' OR original_params !~ '^[0-9a-f]{64}$' OR observed NOT IN
            ('unpaid','paying','paid','channel_closed','close_accepted') OR octet_length(proof_hash)<>32
        OR length(serial) NOT BETWEEN 1 AND 128 OR length(secret_ref) NOT BETWEEN 1 AND 128
        OR octet_length(sealed_proof) NOT BETWEEN 29 AND 2097152 THEN
        RAISE EXCEPTION 'invalid original stop proof' USING ERRCODE='22023'; END IF;
    INSERT INTO meton_inbox.order_stop_proofs VALUES(route->>'channel',route->>'cashEnvironment',route->>'merchant',
        original_trade,original,owner_marker,original_params,observed,proof_hash,serial,secret_ref,sealed_proof,clock_timestamp())
        ON CONFLICT DO NOTHING;
    RETURN EXISTS(SELECT FROM meton_inbox.order_stop_proofs p WHERE
        (p.channel,p.cash_environment,p.merchant,p.trade,p.digest,p.intent,p.marker,p.params_hash,p.outcome)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',original_trade,proof_hash,original,owner_marker,original_params,observed));
END $$;
CREATE FUNCTION meton_inbox.take_order_close(route jsonb,original uuid,owner_marker uuid,original_trade text,
    original_params text,original_dispatch uuid,proof_hash bytea) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_purchase_consumer(route);
    IF original_dispatch IS NULL OR NOT EXISTS(SELECT FROM meton_inbox.order_stop_proofs p WHERE
        (p.channel,p.cash_environment,p.merchant,p.trade,p.digest,p.intent,p.marker,p.params_hash,p.outcome)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',original_trade,proof_hash,original,owner_marker,original_params,'unpaid')) THEN
        RAISE EXCEPTION 'missing unpaid proof for original close' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.order_close_tickets VALUES(route->>'channel',route->>'cashEnvironment',route->>'merchant',original_trade,
        original,owner_marker,original_params,original_dispatch,proof_hash,clock_timestamp()) ON CONFLICT DO NOTHING;
    RETURN FOUND;
END $$;
REVOKE ALL ON meton_inbox.order_stop_proofs,meton_inbox.order_close_tickets FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_inbox.record_order_stop_proof(jsonb,uuid,uuid,text,text,text,bytea,text,text,bytea),
    meton_inbox.take_order_close(jsonb,uuid,uuid,text,text,uuid,bytea) FROM PUBLIC;
