-- 外部票据持久提交后，再以当前写入身份验证原租约。本次事务持有来源栅栏到网络调用结束。
CREATE FUNCTION meton_ledger.current_order_close(route jsonb,original uuid,owner_marker uuid,probe uuid,
    expected bigint,ticket uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_ledger.require_cash_writer(route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    IF meton_ledger.notification_system_id() IS DISTINCT FROM route->>'sourceSystem' THEN
        RAISE EXCEPTION 'close writer retired' USING ERRCODE='42501'; END IF;
    RETURN EXISTS(SELECT FROM meton_ledger.cash_order_stops s JOIN meton_ledger.cash_orders c USING(native_order,intent_id,source_marker)
        WHERE (s.intent_id,s.source_marker,s.lease,s.version,s.close_dispatch,s.lease_generation)=(original,owner_marker,probe,expected,ticket,(route->>'epoch')::bigint)
        AND (c.channel,c.cash_environment,c.merchant_id,c.app_id)=(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
        AND s.next_probe>clock_timestamp() AND s.phase='possibly_sent' AND NOT EXISTS(SELECT FROM meton_ledger.cash_payments p WHERE p.native_order=s.native_order));
END $$;
REVOKE ALL ON FUNCTION meton_ledger.current_order_close(jsonb,uuid,uuid,uuid,bigint,uuid) FROM PUBLIC;
