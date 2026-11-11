-- 独立收件库里的购买处理进度可以重试，不能决定用户余额。退款和旧证据保持各自原处理权。
CREATE TABLE meton_inbox.purchase_consumers(
    channel text NOT NULL, cash_environment text NOT NULL, merchant text NOT NULL, app text NOT NULL,
    consumer name NOT NULL, PRIMARY KEY(channel,cash_environment,merchant,app),
    FOREIGN KEY(channel,cash_environment,merchant,app) REFERENCES meton_inbox.writers
);
CREATE TABLE meton_inbox.purchase_delivery(
    receipt uuid NOT NULL, digest bytea NOT NULL, deployment text NOT NULL, source_name text NOT NULL, app text NOT NULL,
    token uuid NOT NULL, state text NOT NULL CHECK(state IN ('claimed','retry','posted','review','foreign')),
    available_at timestamptz NOT NULL, claimed_at timestamptz NOT NULL, reason text NOT NULL,
    PRIMARY KEY(receipt,digest,deployment,source_name,app), FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.proofs
);
CREATE INDEX pending_purchase_proofs ON meton_inbox.proofs(saved_at,receipt,digest);

CREATE FUNCTION meton_inbox.lock_purchase_consumer(route jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF pg_is_in_recovery() OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
        OR current_setting('synchronous_commit') NOT IN ('on','remote_apply') THEN
        RAISE EXCEPTION 'purchase inbox unavailable' USING ERRCODE='55000'; END IF;
    PERFORM FROM meton_inbox.writers w JOIN meton_inbox.purchase_consumers c USING(channel,cash_environment,merchant,app)
        WHERE (w.channel,w.cash_environment,w.merchant,w.app,w.deployment,w.source_name,w.generation,w.source_system,c.consumer)=
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',route->>'deployment',
         route->>'source',(route->>'epoch')::bigint,route->>'sourceSystem',session_user)
        AND c.consumer<>w.writer AND w.source_system<>meton_inbox.system_id() AND meton_inbox.system_id()=route->>'inboxSystem'
        FOR SHARE OF w,c;
    IF NOT FOUND THEN RAISE EXCEPTION 'purchase consumer retired' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION meton_inbox.claim_purchase_notice(route jsonb)
RETURNS TABLE(receipt_id uuid,proof_hash bytea,lease uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE dep text:=route->>'deployment'; src text:=route->>'source'; app_id text:=route->>'app';
BEGIN
    PERFORM meton_inbox.lock_purchase_consumer(route);
    RETURN QUERY WITH picked AS (
        SELECT p.receipt,p.digest FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt)
        LEFT JOIN meton_inbox.purchase_delivery d ON (d.receipt,d.digest,d.deployment,d.source_name,d.app)=(p.receipt,p.digest,dep,src,app_id)
        WHERE (r.channel,r.cash_environment,r.merchant,r.kind)=(route->>'channel',route->>'cashEnvironment',route->>'merchant','payment')
        AND (d.receipt IS NULL OR (d.state IN ('retry','claimed') AND d.available_at<=clock_timestamp()))
        ORDER BY p.saved_at,p.receipt,p.digest LIMIT 1 FOR UPDATE OF p SKIP LOCKED)
    INSERT INTO meton_inbox.purchase_delivery AS d(receipt,digest,deployment,source_name,app,token,state,claimed_at,available_at,reason)
        SELECT receipt,digest,dep,src,app_id,gen_random_uuid(),'claimed',clock_timestamp(),clock_timestamp()+interval '30 seconds','' FROM picked
        ON CONFLICT(receipt,digest,deployment,source_name,app) DO UPDATE SET token=excluded.token,state='claimed',
            claimed_at=excluded.claimed_at,available_at=excluded.available_at,reason=''
        WHERE d.state IN ('retry','claimed') AND d.available_at<=clock_timestamp()
        RETURNING d.receipt,d.digest,d.token;
END $$;

-- 工作者在本事务持有当前路由和租约的锁，完成来源提交之后才清除收件待处理状态。
CREATE FUNCTION meton_inbox.read_purchase_notice(route jsonb, original uuid, hash bytea, lease uuid)
RETURNS TABLE(delivery text, key_ref text, sealed bytea, conflicted boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_purchase_consumer(route);
    PERFORM FROM meton_inbox.purchase_delivery d WHERE
        (d.receipt,d.digest,d.deployment,d.source_name,d.app,d.token,d.state)=
        (original,hash,route->>'deployment',route->>'source',route->>'app',lease,'claimed') AND d.available_at>clock_timestamp() FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'obsolete purchase claim' USING ERRCODE='55000'; END IF;
    RETURN QUERY SELECT r.delivery,p.recovery_key,p.sealed,EXISTS(SELECT FROM meton_inbox.proofs other
        WHERE other.receipt=r.receipt AND NOT other.first_proof)
        FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt)
        WHERE (r.receipt,p.digest,r.channel,r.cash_environment,r.merchant,r.kind)=
            (original,hash,route->>'channel',route->>'cashEnvironment',route->>'merchant','payment');
END $$;

CREATE FUNCTION meton_inbox.finish_purchase_notice(route jsonb, original uuid, hash bytea, lease uuid, result text, reason_code text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF result IS NULL OR result NOT IN ('retry','posted','review','foreign') OR reason_code IS NULL
        OR reason_code !~ '^[a-z_]{1,48}$' THEN RAISE EXCEPTION 'invalid purchase result' USING ERRCODE='22023'; END IF;
    PERFORM meton_inbox.lock_purchase_consumer(route);
    UPDATE meton_inbox.purchase_delivery d SET state=result,reason=reason_code,available_at=clock_timestamp()+interval '15 seconds'
        WHERE (d.receipt,d.digest,d.deployment,d.source_name,d.app,d.token,d.state)=
        (original,hash,route->>'deployment',route->>'source',route->>'app',lease,'claimed');
    RETURN FOUND;
END $$;
REVOKE ALL ON meton_inbox.purchase_consumers,meton_inbox.purchase_delivery FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_inbox.lock_purchase_consumer(jsonb),meton_inbox.claim_purchase_notice(jsonb),
    meton_inbox.read_purchase_notice(jsonb,uuid,bytea,uuid),meton_inbox.finish_purchase_notice(jsonb,uuid,bytea,uuid,text,text) FROM PUBLIC;
