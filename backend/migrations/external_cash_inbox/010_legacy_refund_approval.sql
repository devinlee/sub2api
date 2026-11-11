-- 成功路径在不可变批准表中既有 target 列又有同名函数参数。以已验的原参数确定归属，不能从别的订单取目标。
DO $fix$
DECLARE definition text:=pg_get_functiondef('meton_inbox.review_legacy_refund_return(jsonb,jsonb,text,jsonb)'::regprocedure);
    anchor text:='(a.marker,a.native_order)=((target->>''marker'')::uuid,(target->>''order'')::bigint)';
BEGIN
    IF cardinality(string_to_array(definition,anchor))<>2 THEN RAISE EXCEPTION 'historical approval lookup changed'; END IF;
    EXECUTE replace(definition,anchor,'(a.marker,a.native_order)=((review_legacy_refund_return.target->>''marker'')::uuid,(review_legacy_refund_return.target->>''order'')::bigint)');
END $fix$;
