-- 外部返还复用原回执投递表；工作目标是原付款，不能因为没有用户退款申请而不处理。
ALTER TABLE meton_inbox.purchase_delivery ADD COLUMN review_epoch bigint, ADD COLUMN review_key uuid,
    ADD CHECK((review_epoch IS NULL)=(review_key IS NULL));

/** 复用已验的原现金合计，调用者提供原付款身份即可，不需要虚构一张退款绑定。 */
CREATE FUNCTION meton_inbox.cash_review_exposure(envelope jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE original meton_inbox.refund_wire_bindings;
BEGIN
    original.envelope:=envelope;
    original.channel:=envelope#>>'{scope,channel}';original.cash_environment:=envelope#>>'{scope,cashEnvironment}';
    original.merchant:=envelope#>>'{scope,merchant}';
    RETURN meton_inbox.original_cash_return_exposure(original);
END $$;

/** 换代或换签章后，原收件沿旧投递主键重新领取；事实与现金身份不变，不清空已验收件。 */
CREATE FUNCTION meton_inbox.claim_external_cash_review(route jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);job meton_inbox.purchase_delivery;facts jsonb;
BEGIN
    WITH picked AS (
        SELECT p.receipt,p.digest FROM meton_inbox.receipts r JOIN meton_inbox.proofs p USING(receipt)
            JOIN meton_inbox.external_cash_returns x USING(receipt,digest)
            LEFT JOIN meton_inbox.purchase_delivery d ON (d.receipt,d.digest,d.deployment,d.source_name,d.app)=
                (p.receipt,p.digest,a.deployment,a.source,route->>'app')
        WHERE (r.channel,r.cash_environment,r.merchant,r.kind)=(route->>'channel',route->>'cashEnvironment',route->>'merchant','external_return')
            AND x.original=meton_inbox.cash_original_identity(jsonb_build_object('scope',route,'cash',x.facts))
            AND (d.receipt IS NULL OR (d.review_epoch,d.review_key) IS DISTINCT FROM (a.epoch,a.key_ref)
                OR d.state IN ('retry','claimed') AND d.available_at<=clock_timestamp())
        ORDER BY p.saved_at,p.receipt,p.digest LIMIT 1 FOR UPDATE OF p SKIP LOCKED
    ) INSERT INTO meton_inbox.purchase_delivery AS d(receipt,digest,deployment,source_name,app,token,state,available_at,claimed_at,reason,review_epoch,review_key)
        SELECT receipt,digest,a.deployment,a.source,route->>'app',gen_random_uuid(),'claimed',clock_timestamp()+interval '30 seconds',clock_timestamp(),'',a.epoch,a.key_ref
        FROM picked ON CONFLICT(receipt,digest,deployment,source_name,app) DO UPDATE SET token=excluded.token,state='claimed',
            available_at=excluded.available_at,claimed_at=excluded.claimed_at,reason='',review_epoch=a.epoch,review_key=a.key_ref
        WHERE (d.review_epoch,d.review_key) IS DISTINCT FROM (a.epoch,a.key_ref) OR d.state IN ('retry','claimed') AND d.available_at<=clock_timestamp()
        RETURNING * INTO job;
    IF job.receipt IS NULL THEN RETURN NULL; END IF;
    SELECT x.facts INTO STRICT facts FROM meton_inbox.external_cash_returns x WHERE (x.receipt,x.digest)=(job.receipt,job.digest);
    RETURN jsonb_build_object('receipt',job.receipt,'digest',encode(job.digest,'hex'),'lease',job.token,
        'order',facts->>'order','transaction',facts->>'transaction');
END $$;

/** 原交易锁先于投递锁，与收件的锁序一致。旧租约和其他应用不能借一个回执读出原现金证明。 */
CREATE FUNCTION meton_inbox.lock_external_cash_review(route jsonb,ref uuid,hash bytea,lease uuid) RETURNS meton_inbox.external_cash_returns
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);x meton_inbox.external_cash_returns;
BEGIN
    SELECT p.* INTO x FROM meton_inbox.external_cash_returns p JOIN meton_inbox.receipts r USING(receipt)
        WHERE (p.receipt,p.digest,r.channel,r.cash_environment,r.merchant,r.kind)=
            (ref,hash,route->>'channel',route->>'cashEnvironment',route->>'merchant','external_return');
    IF x.receipt IS NULL OR x.original IS DISTINCT FROM meton_inbox.lock_original_cash(route,x.facts->>'order',x.facts->>'transaction') THEN
        RAISE EXCEPTION 'original cash review scope differs' USING ERRCODE='42501'; END IF;
    PERFORM FROM meton_inbox.purchase_delivery d WHERE
        (d.receipt,d.digest,d.deployment,d.source_name,d.app,d.token,d.state,d.review_epoch,d.review_key)=
        (ref,hash,a.deployment,a.source,route->>'app',lease,'claimed',a.epoch,a.key_ref) AND d.available_at>clock_timestamp() FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'obsolete original cash review lease' USING ERRCODE='55000'; END IF;
    RETURN x;
END $$;

/** 签章携带完整原付款和当前代次；金额事实只从独立收件重算，调用者不能自报已退金额。 */
CREATE FUNCTION meton_inbox.original_cash_review_result(route jsonb,ref uuid,hash bytea,lease uuid,envelope jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);
    x meton_inbox.external_cash_returns:=meton_inbox.lock_external_cash_review(route,ref,hash,lease);scope jsonb;exposure jsonb;facts jsonb;
BEGIN
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    IF envelope->'scope' IS DISTINCT FROM scope||jsonb_build_object('channel',route->>'channel','cashEnvironment',route->>'cashEnvironment',
            'merchant',route->>'merchant','app',route->>'app')
        OR meton_inbox.cash_original_identity(envelope) IS DISTINCT FROM x.original
        OR coalesce(octet_length(envelope::text),0)>16384 THEN RAISE EXCEPTION 'original cash target differs' USING ERRCODE='42501'; END IF;
    exposure:=meton_inbox.cash_review_exposure(envelope);
    IF exposure IS NULL OR coalesce((exposure->>'pendingCommit')::boolean,true) THEN RETURN jsonb_build_object('state','recorded'); END IF;
    exposure:=exposure-'pendingCommit';
    facts:=jsonb_build_object('format',1,'scope',scope,'envelope',envelope,'cashExposure',exposure,
        'cashExposureHash',encode(sha256(convert_to(exposure::text,'UTF8')),'hex'),'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','review','facts',facts,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.cash.original.review.v1',facts)::text,'UTF8'),a.seal_key),'hex'));
END $$;

CREATE FUNCTION meton_inbox.finish_external_cash_review(route jsonb,ref uuid,hash bytea,lease uuid,result text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.lock_external_cash_review(route,ref,hash,lease);
    IF result IS NULL OR result NOT IN ('review','original_unavailable','retry') THEN RAISE EXCEPTION 'invalid cash review result' USING ERRCODE='22023'; END IF;
    UPDATE meton_inbox.purchase_delivery d SET state=CASE WHEN result='review' THEN 'review' ELSE 'retry' END,reason=result,
        available_at=CASE WHEN result='review' THEN 'infinity'::timestamptz ELSE clock_timestamp()+interval '15 seconds' END
        WHERE (d.receipt,d.digest,d.deployment,d.source_name,d.app,d.token)=(ref,hash,route->>'deployment',route->>'source',route->>'app',lease);
    RETURN FOUND;
END $$;

/** 同一返还号新增冲突版本时，原归属也必须重新核对，不能只更新新报来的订单。 */
CREATE FUNCTION meton_inbox.wake_original_cash_reviews() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    UPDATE meton_inbox.purchase_delivery d SET token=gen_random_uuid(),state='retry',available_at=clock_timestamp(),reason='new_external_report'
        WHERE d.receipt=NEW.receipt AND d.review_epoch IS NOT NULL;
    RETURN NEW;
END $$;
CREATE TRIGGER original_cash_review_arrived AFTER INSERT ON meton_inbox.external_cash_returns
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.wake_original_cash_reviews();
ALTER TABLE meton_inbox.external_cash_returns ENABLE ALWAYS TRIGGER original_cash_review_arrived;
REVOKE ALL ON FUNCTION meton_inbox.cash_review_exposure(jsonb),meton_inbox.claim_external_cash_review(jsonb),
    meton_inbox.lock_external_cash_review(jsonb,uuid,bytea,uuid),meton_inbox.original_cash_review_result(jsonb,uuid,bytea,uuid,jsonb),
    meton_inbox.finish_external_cash_review(jsonb,uuid,bytea,uuid,text),meton_inbox.wake_original_cash_reviews() FROM PUBLIC;
