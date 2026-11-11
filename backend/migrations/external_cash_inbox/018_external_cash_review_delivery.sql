-- 新增原返还事实后，沿现有结清工作者通知所有受影响原退款；来源恢复不会抹掉独立收件。
ALTER TABLE meton_inbox.external_cash_returns ADD COLUMN recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id();

/** 只作原交易身份计算；传输与消费入口仍须调用已有 lock_original_cash 取得原交易锁。 */
CREATE FUNCTION meton_inbox.cash_original_identity(e jsonb) RETURNS bytea LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT sha256(convert_to(jsonb_build_array(e#>>'{scope,channel}',e#>>'{scope,cashEnvironment}',e#>>'{scope,merchant}',
        e#>>'{scope,app}',e#>>'{cash,order}',e#>>'{cash,transaction}')::text,'UTF8'))
$$;

/** 原付款的已知返还是两类实际现金事实之和。冲突金额另列；既不任选一个值，也不把超额裁剪成原付款。 */
CREATE FUNCTION meton_inbox.original_cash_return_exposure(b meton_inbox.refund_wire_bindings) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE original_key bytea:=meton_inbox.cash_original_identity(b.envelope);x jsonb;refunds jsonb;
    reports text;total numeric;cap numeric;fresh boolean;digest text;
BEGIN
    x:=meton_inbox.external_cash_return_summary(original_key,'CNY');
    IF (x->>'events')::bigint=0 THEN RETURN NULL; END IF;
    SELECT string_agg(encode(v.digest,'hex'),',' ORDER BY v.receipt,v.digest),
        coalesce(bool_or(v.recorded_xid=pg_current_xact_id()),false) INTO reports,fresh
        FROM meton_inbox.external_cash_returns v WHERE v.receipt IN (
            SELECT p.receipt FROM meton_inbox.external_cash_returns p WHERE p.original=original_key);
    -- 同一渠道退款号在不同原退款下出现时保持归属争议，不在两边各加一次现金。
    WITH candidates AS (
        SELECT p.refund,p.economic_hash,p.fields,p.observed_xid,other.envelope,
            coalesce(p.fields->>'refundID','invalid:'||p.refund::text) provider_id
        FROM meton_inbox.refund_positive_cash p JOIN meton_inbox.refund_wire_bindings other USING(refund)
        WHERE (other.channel,other.cash_environment,other.merchant)=(b.channel,b.cash_environment,b.merchant)
    ), related AS (
        SELECT DISTINCT provider_id FROM candidates WHERE meton_inbox.cash_original_identity(envelope)=original_key
    ), grouped AS (
        SELECT c.provider_id,count(DISTINCT c.refund)=1 AND count(DISTINCT c.economic_hash)=1
            AND bool_and(meton_inbox.cash_original_identity(c.envelope)=original_key
                AND c.fields->>'refundID'~'^[A-Za-z0-9_.:-]{1,64}$'
                AND (c.fields->>'order',c.fields->>'transaction',c.fields->>'refundOrder',c.fields->>'total')=
                    (c.envelope#>>'{cash,order}',c.envelope#>>'{cash,transaction}',c.envelope#>>'{cash,refundOrder}',c.envelope#>>'{cash,total}')
                AND c.fields->>'refundFen'=c.envelope#>>'{cash,refundFen}'
                AND (coalesce((c.envelope#>>'{cash,payerTotalUnrecorded}')::boolean,false)
                    OR c.fields->>'payerTotal'=c.envelope#>>'{cash,payerTotal}')
                AND CASE WHEN c.fields->>'payerRefund'~'^[0-9]{1,19}$' AND c.fields->>'payerTotal'~'^[0-9]{1,19}$'
                    THEN (c.fields->>'payerRefund')::numeric BETWEEN 0 AND least((c.fields->>'payerTotal')::numeric,(c.envelope#>>'{cash,refundFen}')::numeric)
                    ELSE false END) good,
            max(CASE WHEN c.fields->>'payerRefund'~'^[0-9]{1,19}$' THEN (c.fields->>'payerRefund')::numeric END) amount,
            bool_or(c.observed_xid=pg_current_xact_id()) pending_commit,
            string_agg(encode(c.economic_hash,'hex')||':'||c.refund::text,',' ORDER BY c.refund,c.economic_hash) material
        FROM candidates c JOIN related r USING(provider_id) GROUP BY c.provider_id
    )
    SELECT jsonb_build_object('knownFen',coalesce(sum(amount) FILTER(WHERE good),0)::text,
        'ambiguousEvents',count(*) FILTER(WHERE good IS NOT TRUE),
        'pendingCommit',coalesce(bool_or(pending_commit),false),
        'evidence',coalesce(string_agg(material,';' ORDER BY provider_id),''))
        INTO refunds FROM grouped;
    total:=(x->>'confirmedFen')::numeric+(refunds->>'knownFen')::numeric;
    IF NOT coalesce((b.envelope#>>'{cash,payerTotalUnrecorded}')::boolean,false) THEN cap:=(b.envelope#>>'{cash,payerTotal}')::numeric; END IF;
    digest:=encode(sha256(convert_to(jsonb_build_array(reports,refunds->>'evidence')::text,'UTF8')),'hex');
    RETURN jsonb_build_object('format',1,'original',encode(original_key,'hex'),'currency','CNY','externalEvents',x->'events',
        'ambiguousExternalEvents',x->'ambiguousEvents','ambiguousRefundEvents',refunds->'ambiguousEvents',
        'knownExternalFen',x->>'confirmedFen','knownRefundFen',refunds->>'knownFen','knownReturnedFen',total::text,
        'payerCapFen',cap::text,'knownExcessFen',CASE WHEN cap IS NULL THEN NULL ELSE greatest(total-cap,0)::text END,
        'evidenceHash',digest,'pendingCommit',fresh OR (refunds->>'pendingCommit')::boolean);
END $$;

/** 同一事件换归属时同时唤醒旧、新原付款，已经完成的退款也须接收迟到的真实现金事实。 */
CREATE FUNCTION meton_inbox.external_cash_review_arrived() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE item record;
BEGIN
    FOR item IN SELECT DISTINCT b.refund FROM meton_inbox.refund_wire_bindings b
        WHERE meton_inbox.cash_original_identity(b.envelope) IN (
            SELECT original FROM meton_inbox.external_cash_returns WHERE receipt=NEW.receipt)
    LOOP PERFORM meton_inbox.wake_refund_settlement(item.refund); END LOOP;
    RETURN NEW;
END $$;
CREATE TRIGGER external_cash_review_arrived AFTER INSERT ON meton_inbox.external_cash_returns
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.external_cash_review_arrived();
ALTER TABLE meton_inbox.external_cash_returns ENABLE ALWAYS TRIGGER external_cash_review_arrived;

-- 原退款正向成功事实先照旧留存。只有独立事务中已提交的现金材料才会签发新的来源核对证明。
DO $review$
DECLARE body text:=pg_get_functiondef('meton_inbox.original_refund_cash_result(jsonb,uuid)'::regprocedure);
    declarations text:='accepted meton_inbox.refund_positive_cash;';
    point text:='IF EXISTS(SELECT FROM meton_inbox.refund_cash_disputes WHERE refund=ref) THEN';
BEGIN
    IF cardinality(string_to_array(body,declarations))<>2 OR cardinality(string_to_array(body,point))<>2 THEN
        RAISE EXCEPTION 'original cash resolution changed'; END IF;
    body:=replace(body,declarations,'exposure jsonb; exposure_hash bytea; '||declarations);
    body:=replace(body,point,$new$
    exposure:=meton_inbox.original_cash_return_exposure(b);
    IF exposure IS NOT NULL THEN
        IF fresh OR coalesce((exposure->>'pendingCommit')::boolean,true) THEN RETURN jsonb_build_object('state','recorded'); END IF;
        exposure:=exposure-'pendingCommit';
        exposure_hash:=sha256(convert_to(exposure::text,'UTF8'));
        facts:=jsonb_build_object('format',1,'scope',scope,'envelope',b.envelope,'confirmedCashVariants',positive_count,
            'reviewHash',encode(exposure_hash,'hex'),'cashExposure',exposure,'cashExposureHash',encode(exposure_hash,'hex'),
            'validUntil',clock_timestamp()+interval '25 seconds');
        RETURN jsonb_build_object('state','review','confirmedCashVariants',positive_count,'facts',facts,'mac',encode(meton_inbox.refund_seal_mac(
            convert_to(jsonb_build_array('meton.refund.disputed.v1',facts)::text,'UTF8'),a.seal_key),'hex'));
    END IF;
    $new$||point);
    EXECUTE body;
END $review$;
REVOKE ALL ON FUNCTION meton_inbox.cash_original_identity(jsonb),meton_inbox.original_cash_return_exposure(meton_inbox.refund_wire_bindings),
    meton_inbox.external_cash_review_arrived() FROM PUBLIC;

-- 迁移时将原有外部事实交给原队列；既有成功回执、独立签章及恢复再投递规则不变。
SELECT meton_inbox.wake_refund_settlement(b.refund) FROM meton_inbox.refund_wire_bindings b
    WHERE EXISTS(SELECT FROM meton_inbox.external_cash_returns r WHERE r.original=meton_inbox.cash_original_identity(b.envelope));
