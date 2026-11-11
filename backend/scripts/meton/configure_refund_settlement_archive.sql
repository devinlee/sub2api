\set ON_ERROR_STOP on
BEGIN;
-- 结清身份与原代次、两个库和密钥版本绑定。重复运行只能恢复相同登记。
SELECT EXISTS(SELECT FROM meton_inbox.refund_gate_authorities a JOIN pg_roles r ON r.rolname=:'worker_role'
    WHERE (a.deployment,a.source,a.epoch,a.key_ref)=(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid)
        AND :'source_system'<>:'inbox_system' AND meton_inbox.system_id()=:'inbox_system' AND a.source_system=:'source_system' AND r.rolname NOT IN (a.sender,a.stopper) AND NOT EXISTS(SELECT FROM meton_inbox.writers w WHERE w.writer=r.rolname)
        AND r.rolcanlogin AND NOT (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)) AS eligible \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'refund settlement authority differs'; END $$;
\endif
INSERT INTO meton_inbox.refund_resolution_roles VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'worker_role') ON CONFLICT DO NOTHING;
SELECT EXISTS(SELECT FROM meton_inbox.refund_resolution_roles WHERE (deployment,source,epoch,key_ref,resolver)=
    (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'worker_role'::name)) AS original \gset
\if :original
GRANT USAGE ON SCHEMA meton_inbox TO :"worker_role";
GRANT EXECUTE ON FUNCTION meton_inbox.system_id(),meton_inbox.refund_settlement_ready(jsonb),meton_inbox.claim_refund_settlement(jsonb),meton_inbox.original_refund_cash_result(jsonb,uuid),meton_inbox.finish_refund_settlement(jsonb,uuid,bigint,uuid,text),
    meton_inbox.claim_external_cash_review(jsonb),meton_inbox.original_cash_review_result(jsonb,uuid,bytea,uuid,jsonb),
    meton_inbox.finish_external_cash_review(jsonb,uuid,bytea,uuid,text),
    meton_inbox.bind_cash_dispute(jsonb,jsonb),meton_inbox.cash_dispute_result(jsonb,uuid),
    meton_inbox.bind_original_refund_aftercare(jsonb,jsonb),meton_inbox.original_refund_aftercare_result(jsonb,uuid),
    meton_inbox.original_alternative_material(jsonb,uuid,uuid),meton_inbox.original_alternative_decision(jsonb,uuid),
    meton_inbox.decide_original_alternative(jsonb,jsonb,text),meton_inbox.claim_alternative_cash(jsonb),
    meton_inbox.finish_alternative_cash(jsonb,uuid,uuid,text),meton_inbox.prepare_alternative_cash(jsonb,uuid),meton_inbox.alternative_cash_result(jsonb,uuid) TO :"worker_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'settlement role or signing generation already used'; END $$;
\endif
COMMIT;
