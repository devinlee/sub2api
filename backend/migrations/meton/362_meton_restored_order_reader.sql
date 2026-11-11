-- 当前账号的新会话可只读原订单；旧收银台的写授权仍绑定首次交接的原代次。
DO $reader$
DECLARE body text:=pg_get_functiondef('meton_ledger.read_original_purchase(jsonb,uuid,timestamptz)'::regprocedure);
    original constant text:='WHERE h.intent_id=i AND h.origin=o AND u.status=''active'' AND u.deleted_at IS NULL';
BEGIN
    IF cardinality(string_to_array(body,original))<>2 THEN
        RAISE EXCEPTION 'original purchase reader changed'; END IF;
    -- 复用既有原账号完整接续链。仅忽略已证明接续的代次；开户号、用户及来源标记必须逐项保持。
    -- apply_checkout_http 的当前人员、Key、fence 和旧 Web 复验均不变，此处不授予报价或付款权限。
    EXECUTE replace(body,original,$current$
        WHERE h.intent_id=i AND (h.origin-'epoch')=(o-'epoch')
            AND meton_ledger.refund_owner_succeeded(m,(h.origin->>'epoch')::bigint)
            AND u.status='active' AND u.deleted_at IS NULL$current$);
END $reader$;
