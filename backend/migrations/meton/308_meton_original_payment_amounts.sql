-- 报价永久属于原商品；渠道签名的交易总额、付款人实付和原订单报价各自保留。异额不能兑换额度。
DO $amounts$
DECLARE basis text:=pg_get_functiondef('meton_ledger.notification_origin(text,text,bigint,text,text,text,text,jsonb)'::regprocedure);
    observe_def text:=pg_get_functiondef('meton_ledger.observe_cash_payment(text,text,bigint,jsonb,jsonb)'::regprocedure);
    fulfil_def text:=pg_get_functiondef('meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint)'::regprocedure);
    guard_def text:=pg_get_functiondef('meton_ledger.guard_native_purchase()'::regprocedure);
    reflect_def text:=pg_get_functiondef('meton_ledger.sync_native_cash_status()'::regprocedure);
    amount_gate constant text:='OR o.price_fen IS DISTINCT FROM (facts->>''total'')::bigint';
    refund_total constant text:='(facts->>''transaction'',o.price_fen,(facts->>''payerTotal'')::bigint,o.currency,o.currency)';
    first_cash constant text:='first_payment:=NOT EXISTS(SELECT FROM meton_ledger.cash_payments WHERE native_order=o.native_order)';
    qualify constant text:='IF first_payment AND';
    conflict_at constant text:='RETURN jsonb_build_object(''state'',''conflict'');';
    unsettled constant text:='IF meton_ledger.order_account_restricted(o) OR EXISTS(';
    hard_guard constant text:='AND OLD.paid_at=NEW.paid_at
                 AND OLD.payment_trade_no=NEW.payment_trade_no';
    complete_at constant text:='SET status=''COMPLETED'',completed_at=e.recorded_at';
    same_trade constant text:='AND o.payment_trade_no=p.channel_transaction';
BEGIN
    IF cardinality(string_to_array(basis,amount_gate))<>2 OR cardinality(string_to_array(basis,refund_total))<>2 OR
        cardinality(string_to_array(observe_def,first_cash))<>2 OR cardinality(string_to_array(observe_def,qualify))<>2 OR
        cardinality(string_to_array(observe_def,conflict_at))<>2 OR cardinality(string_to_array(fulfil_def,unsettled))<>2 OR
        cardinality(string_to_array(guard_def,hard_guard))<>2 OR cardinality(string_to_array(reflect_def,complete_at))<>2 OR
        cardinality(string_to_array(reflect_def,same_trade))<>2 THEN RAISE EXCEPTION 'original payment posting changed'; END IF;
    basis:=replace(basis,amount_gate,$bounds$OR (facts->>'total')::bigint IS NULL OR (facts->>'total')::bigint<=0
        OR (facts->>'payerTotal')::bigint IS NULL OR (facts->>'payerTotal')::bigint NOT BETWEEN 0 AND (facts->>'total')::bigint$bounds$);
    EXECUTE replace(basis,refund_total,'(facts->>''transaction'',(facts->>''total'')::bigint,(facts->>''payerTotal'')::bigint,o.currency,o.currency)');
    observe_def:=replace(observe_def,first_cash,$award$first_payment:=NOT EXISTS(SELECT FROM meton_ledger.cash_order_awards
        WHERE native_order=o.native_order) AND NOT EXISTS(SELECT FROM meton_ledger.cash_payment_conflicts conflict
        JOIN meton_ledger.cash_payments disputed USING(payment_id) WHERE disputed.native_order=o.native_order OR conflict.claimed_intent=o.intent_id)$award$);
    observe_def:=replace(observe_def,conflict_at,'PERFORM meton_ledger.restrict_unposted_payment(p.payment_id); '||conflict_at);
    EXECUTE replace(observe_def,qualify,'IF first_payment AND total=o.price_fen AND payer=o.price_fen AND');
    -- 已完成的经济事实照旧返回。升级前只取得履约资格、尚未入账的异额，重试也不能用旧资格发放额度。
    EXECUTE replace(fulfil_def,unsettled,'IF p.order_fen<>o.price_fen OR p.payer_fen<>o.price_fen OR meton_ledger.order_account_restricted(o) OR EXISTS(');
    -- 先到的一笔异常款已经留下真实原生 PAID。只在原商品合法购买同一事务中切换到真正履约的交易，
    -- 原生投影能容纳的只是一个交易号，早到的钱仍完整留在 cash_payments 和未履约现金份额中。
    EXECUTE replace(guard_def,hard_guard,$winning$AND EXISTS(SELECT FROM meton_ledger.cash_payments seen
                 WHERE seen.native_order=OLD.id AND seen.channel_transaction=OLD.payment_trade_no AND seen.paid_at=OLD.paid_at)
                 AND EXISTS(SELECT FROM meton_ledger.cash_order_awards winner WHERE winner.native_order=NEW.id AND winner.payment_id=p.payment_id)$winning$);
    reflect_def:=replace(reflect_def,complete_at,'SET status=''COMPLETED'',payment_trade_no=p.channel_transaction,paid_at=p.paid_at,completed_at=e.recorded_at');
    EXECUTE replace(reflect_def,same_trade,'AND EXISTS(SELECT FROM meton_ledger.cash_order_awards winner WHERE winner.native_order=o.id AND winner.payment_id=p.payment_id)');
END $amounts$;
