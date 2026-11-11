\set ON_ERROR_STOP on
BEGIN;
-- 结清身份与原代次、两个库和密钥版本绑定。重复运行只能恢复相同登记。
SELECT EXISTS(SELECT FROM meton_ledger.refund_gate_authorities a JOIN pg_roles r ON r.rolname=:'worker_role'
    WHERE (a.deployment,a.source,a.epoch,a.key_ref)=(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid)
        AND :'source_system'<>:'inbox_system' AND meton_ledger.notification_system_id()=:'source_system' AND a.inbox_system=:'inbox_system' AND NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_workers d WHERE d.worker_role=r.rolname)
        AND r.rolcanlogin AND NOT (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)) AS eligible \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'refund settlement authority differs'; END $$;
\endif
INSERT INTO meton_ledger.refund_settlement_roles VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'worker_role') ON CONFLICT DO NOTHING;
SELECT EXISTS(SELECT FROM meton_ledger.refund_settlement_roles WHERE (deployment,source,epoch,key_ref,resolver)=
    (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'worker_role'::name)) AS original \gset
\if :original
GRANT USAGE ON SCHEMA meton_ledger TO :"worker_role";
GRANT EXECUTE ON FUNCTION meton_ledger.notification_system_id(),meton_ledger.refund_settlement_ready(jsonb),meton_ledger.resolve_original_refund(jsonb,uuid,jsonb),
    meton_ledger.original_cash_review_origin(jsonb,text,text),meton_ledger.record_original_cash_review(jsonb,jsonb),
    meton_ledger.prepare_cash_dispute_origin(jsonb,text,text),meton_ledger.apply_cash_dispute_status(jsonb,jsonb),
    meton_ledger.read_original_refund_aftercare(jsonb,uuid),meton_ledger.open_original_refund_aftercare(jsonb,uuid,text),
    meton_ledger.prepare_original_refund_aftercare(jsonb,uuid),meton_ledger.apply_original_refund_verification(jsonb,uuid,jsonb),
    meton_ledger.prepare_original_alternative(jsonb,uuid,jsonb),meton_ledger.prepare_original_alternative_stop(jsonb,uuid),
    meton_ledger.apply_original_alternative_decision(jsonb,uuid,jsonb),
    meton_ledger.original_alternative_cash_permit(jsonb,uuid,jsonb),meton_ledger.resolve_alternative_refund(jsonb,uuid,jsonb),
    meton_ledger.resolve_alternative_closed(jsonb,uuid,jsonb) TO :"worker_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'settlement role or signing generation already used'; END $$;
\endif
COMMIT;
