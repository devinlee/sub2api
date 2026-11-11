-- 只接回原 CLOSED 证明；恢复链、原签发身份与当前密钥同时成立才允许复用原占用释放，不授予历史退款发送权。
DO $failure$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb)'::regprocedure);
    needle text:=$old$(g.accepted_epoch,g.source_system,g.inbox_system) IS DISTINCT FROM
        (a.epoch,meton_ledger.notification_system_id(),a.inbox_system)$old$;
BEGIN
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'original refund generation guard changed'; END IF;
    EXECUTE replace(body,needle,$current$(g.source_system,g.inbox_system) IS DISTINCT FROM
        (meton_ledger.notification_system_id(),a.inbox_system) OR
        (g.accepted_epoch<>a.epoch AND NOT coalesce(choice='failed' AND EXISTS(
            SELECT FROM public.meton_managed_creations m JOIN meton_ledger.refund_dispatch_issuers i ON i.refund=g.refund
            WHERE (m.environment,m.source,m.epoch,m.source_marker)=(a.deployment,a.source,a.epoch,g.marker)
                AND meton_ledger.refund_owner_succeeded(m,g.accepted_epoch)
                AND (i.epoch,i.source_system,i.inbox_system)=(g.accepted_epoch,g.source_system,g.inbox_system)
                AND f->'originalScope'=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',i.epoch,
                    'sourceSystem',i.source_system,'inboxSystem',i.inbox_system,'keyRef',i.key_ref)),false))$current$);
END $failure$;
