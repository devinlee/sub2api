\set ON_ERROR_STOP on
-- 兼容已有隔离配置；真实现金必须显式指定，禁止由错误或空值推定。
\if :{?cash_environment}
\else
\set cash_environment isolated
\endif
BEGIN;
SELECT EXISTS(SELECT FROM meton_inbox.refund_gate_authorities a JOIN meton_inbox.writers w
    ON (w.deployment,w.source_name,w.generation,w.source_system)=(a.deployment,a.source,a.epoch,a.source_system)
    JOIN pg_roles r ON r.rolname=a.sender WHERE (a.deployment,a.source,a.epoch,a.key_ref,a.source_system,a.sender,w.channel,w.cash_environment,w.merchant,w.app)=
        (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'source_system',:'worker_role'::name,'wechatpay',:'cash_environment',:'merchant',:'app')
        AND :'cash_environment' IN ('isolated','live') AND meton_inbox.system_id()=:'inbox_system' AND a.source_system<>:'inbox_system' AND r.rolcanlogin
        AND NOT (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)) AS valid_archive \gset
\if :valid_archive
\else
DO $$ BEGIN RAISE EXCEPTION 'original archive, route, signing version or worker role differs'; END $$;
\endif
INSERT INTO meton_inbox.refund_wire_workers VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'worker_role') ON CONFLICT DO NOTHING;
SELECT EXISTS(SELECT FROM meton_inbox.refund_wire_workers WHERE (deployment,source,epoch,key_ref,worker_role)=
    (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'worker_role'::name)) AS original_role \gset
\if :original_role
GRANT USAGE ON SCHEMA meton_inbox TO :"worker_role";
GRANT EXECUTE ON FUNCTION meton_inbox.system_id(),meton_inbox.refund_dispatch_ready(jsonb),meton_inbox.bind_original_refund_dispatch(jsonb,jsonb,text,jsonb,text,text),
    meton_inbox.start_bound_refund_io(jsonb,uuid,uuid,text,text),meton_inbox.hold_bound_refund_io(jsonb,uuid,uuid,text),
    meton_inbox.retire_original_refund_sender(jsonb,uuid,uuid,text),meton_inbox.retire_elapsed_refund_sender(jsonb,uuid,uuid),
    meton_inbox.record_original_refund_transport(jsonb,uuid,text,text,bytea,bytea,jsonb,text,bytea),
    meton_inbox.authorize_recovered_refund_lookup(jsonb,jsonb,text),meton_inbox.record_recovered_refund_get(jsonb,uuid,text,bytea,bytea,jsonb,text,bytea,text),
    meton_inbox.begin_alternative_cash(jsonb,jsonb),meton_inbox.hold_alternative_cash(jsonb,text),meton_inbox.record_alternative_cash(jsonb,text,jsonb,bytea,text,bytea) TO :"worker_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'retired archive role cannot be registered again'; END $$;
\endif
COMMIT;
