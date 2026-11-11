-- 原现金仍在独立归档中；来源回退不能沿用旧的“已处理”结论，也不能把旧租约贴到新代次。
ALTER TABLE meton_inbox.purchase_delivery ADD COLUMN authority_epoch bigint CHECK(authority_epoch>0);
CREATE INDEX purchase_delivery_recovery_route ON meton_inbox.purchase_delivery
    (deployment,source_name,app,authority_epoch,receipt,digest);

/** 只唤醒同一路由的原证明；来源再核原处置，本函数不证明可以入账。 */
CREATE FUNCTION meton_inbox.recheck_original_purchase_notices(route jsonb,notice_kind text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_purchase_consumer(route);
    IF notice_kind IS NULL OR notice_kind NOT IN ('payment','payment_query') THEN
        RAISE EXCEPTION 'invalid purchase replay kind' USING ERRCODE='22023'; END IF;
    IF EXISTS(SELECT FROM meton_inbox.purchase_delivery d WHERE
        (d.deployment,d.source_name,d.app)=(route->>'deployment',route->>'source',route->>'app')
        AND d.authority_epoch>(route->>'epoch')::bigint) THEN
        RAISE EXCEPTION 'purchase replay generation regressed' USING ERRCODE='55000'; END IF;
    WITH batch AS (
        SELECT d.receipt,d.digest FROM meton_inbox.purchase_delivery d JOIN meton_inbox.receipts r USING(receipt)
        WHERE (d.deployment,d.source_name,d.app)=(route->>'deployment',route->>'source',route->>'app')
            AND (r.channel,r.cash_environment,r.merchant,r.kind)=
                (route->>'channel',route->>'cashEnvironment',route->>'merchant',notice_kind)
            AND d.authority_epoch IS DISTINCT FROM (route->>'epoch')::bigint
        ORDER BY d.receipt,d.digest LIMIT 32 FOR UPDATE OF d SKIP LOCKED
    ) UPDATE meton_inbox.purchase_delivery d SET authority_epoch=(route->>'epoch')::bigint,
        token=gen_random_uuid(),state='retry',available_at=clock_timestamp(),reason='source_recovery_recheck'
        FROM batch b WHERE (d.receipt,d.digest)=(b.receipt,b.digest)
            AND (d.deployment,d.source_name,d.app)=(route->>'deployment',route->>'source',route->>'app');
END $$;
REVOKE ALL ON FUNCTION meton_inbox.recheck_original_purchase_notices(jsonb,text) FROM PUBLIC;

DO $replay$
DECLARE body text; signature text; kind text; needle text;
BEGIN
    FOREACH kind IN ARRAY ARRAY['payment','payment_query'] LOOP
        signature:=CASE WHEN kind='payment' THEN 'meton_inbox.claim_purchase_notice(jsonb)' ELSE 'meton_inbox.claim_payment_query(jsonb)' END;
        body:=pg_get_functiondef(signature::regprocedure);
        needle:='PERFORM meton_inbox.lock_purchase_consumer(route);';
        IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'purchase claim guard changed'; END IF;
        body:=replace(body,needle,needle||format(' PERFORM meton_inbox.recheck_original_purchase_notices(route,%L);',kind));
        needle:='claimed_at,available_at,reason)';
        IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'purchase claim columns changed'; END IF;
        body:=replace(body,needle,'claimed_at,available_at,reason,authority_epoch)');
        needle:='interval ''30 seconds'','''' FROM picked';
        IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'purchase claim values changed'; END IF;
        body:=replace(body,needle,'interval ''30 seconds'','''',(route->>''epoch'')::bigint FROM picked');
        needle:='available_at=excluded.available_at,reason=''''';
        IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'purchase claim update changed'; END IF;
        EXECUTE replace(body,needle,needle||',authority_epoch=excluded.authority_epoch');

        signature:=CASE WHEN kind='payment' THEN 'meton_inbox.read_purchase_notice(jsonb,uuid,bytea,uuid)' ELSE 'meton_inbox.read_payment_query(jsonb,uuid,bytea,uuid)' END;
        body:=pg_get_functiondef(signature::regprocedure);
        needle:='AND d.available_at>clock_timestamp()';
        IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'purchase read lease changed'; END IF;
        EXECUTE replace(body,needle,'AND d.authority_epoch=(route->>''epoch'')::bigint '||needle);
    END LOOP;
    -- 完成入口由三类证明共用；仅为本次改变的两条付款路径增加代次核对。
    body:=pg_get_functiondef('meton_inbox.finish_purchase_notice(jsonb,uuid,bytea,uuid,text,text)'::regprocedure);
    needle:='lease,''claimed'');';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'purchase finish lease changed'; END IF;
    EXECUTE replace(body,needle,$guard$lease,'claimed') AND (d.authority_epoch=(route->>'epoch')::bigint
        OR EXISTS(SELECT FROM meton_inbox.receipts r WHERE r.receipt=d.receipt AND r.kind='refund'));$guard$);
END $replay$;
