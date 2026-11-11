-- 确定失败的验证器已有名为 d 的原发送决定。争议表使用独立别名，否则正常关闭也会因列名歧义而永久重试。
DO $closed$
DECLARE body text:=pg_get_functiondef('meton_inbox.original_refund_failure(jsonb,uuid,bytea,uuid)'::regprocedure);
    point constant text:='FROM meton_inbox.refund_cash_disputes d WHERE d.refund=ref';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original closed refund dispute check changed'; END IF;
    EXECUTE replace(body,point,'FROM meton_inbox.refund_cash_disputes disputed WHERE disputed.refund=ref');
END $closed$;
