-- 来源回退也会丢失原 CLOSED 观察与占用释放。重新投递原证明，但不恢复旧消费者或发送者的权限。
DO $replay$
DECLARE body text; needle text;
BEGIN
    body:=pg_get_functiondef('meton_inbox.recheck_original_purchase_notices(jsonb,text)'::regprocedure);
    needle:='notice_kind NOT IN (''payment'',''payment_query'')';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'cash replay kinds changed'; END IF;
    EXECUTE replace(body,needle,'notice_kind NOT IN (''payment'',''payment_query'',''refund'')');

    body:=pg_get_functiondef('meton_inbox.claim_refund_notice(jsonb)'::regprocedure);
    needle:='PERFORM meton_inbox.lock_purchase_consumer(route);';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'refund claim guard changed'; END IF;
    body:=replace(body,needle,needle||' PERFORM meton_inbox.recheck_original_purchase_notices(route,''refund'');');
    needle:='claimed_at,available_at,reason)';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'refund claim columns changed'; END IF;
    body:=replace(body,needle,'claimed_at,available_at,reason,authority_epoch)');
    needle:='interval ''30 seconds'','''' FROM picked';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'refund claim values changed'; END IF;
    body:=replace(body,needle,'interval ''30 seconds'','''',(route->>''epoch'')::bigint FROM picked');
    needle:='available_at=excluded.available_at,reason=''''';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'refund claim update changed'; END IF;
    EXECUTE replace(body,needle,needle||',authority_epoch=excluded.authority_epoch');

    body:=pg_get_functiondef('meton_inbox.read_refund_notice(jsonb,uuid,bytea,uuid)'::regprocedure);
    needle:='AND d.available_at>clock_timestamp()';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'refund read lease changed'; END IF;
    EXECUTE replace(body,needle,'AND d.authority_epoch=(route->>''epoch'')::bigint '||needle);

    body:=pg_get_functiondef('meton_inbox.finish_purchase_notice(jsonb,uuid,bytea,uuid,text,text)'::regprocedure);
    needle:=$old$(d.authority_epoch=(route->>'epoch')::bigint
        OR EXISTS(SELECT FROM meton_inbox.receipts r WHERE r.receipt=d.receipt AND r.kind='refund'))$old$;
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'refund finish generation changed'; END IF;
    EXECUTE replace(body,needle,'d.authority_epoch=(route->>''epoch'')::bigint');
END $replay$;

-- 旧签发范围只用于定位已经退役的原发送者；最终证明由当前权威签名，原付款、原目标和退役证据仍逐项核对。
DO $failure$
DECLARE body text:=pg_get_functiondef('meton_inbox.original_refund_failure(jsonb,uuid,bytea,uuid)'::regprocedure);
    needle text:='IF scope IS DISTINCT FROM d.issued_scope-''validUntil'' THEN RETURN jsonb_build_object(''state'',''review''); END IF;';
BEGIN
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'original failure scope changed'; END IF;
    body:=replace(body,needle,$scope$IF (scope-ARRAY['epoch','keyRef']) IS DISTINCT FROM (d.issued_scope-ARRAY['validUntil','epoch','keyRef']) OR
        ((d.issued_scope->>'epoch')::bigint BETWEEN 1 AND a.epoch) IS NOT TRUE OR
        (d.issued_scope->>'keyRef')::uuid IS NULL THEN RETURN jsonb_build_object('state','review'); END IF;$scope$);
    needle:='facts:=jsonb_build_object(''format'',1,''scope'',scope,''target'',d.target';
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'original failure proof changed'; END IF;
    EXECUTE replace(body,needle,'facts:=jsonb_build_object(''format'',1,''originalScope'',d.issued_scope-''validUntil'',''scope'',scope,''target'',d.target');
END $failure$;
