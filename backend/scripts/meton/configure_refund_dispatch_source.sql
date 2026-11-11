\set ON_ERROR_STOP on
-- 兼容已有隔离配置；真实现金必须显式指定，禁止由错误或空值推定。
\if :{?cash_environment}
\else
\set cash_environment isolated
\endif
BEGIN;
LOCK TABLE meton_ledger.refund_dispatch_policies,meton_ledger.refund_dispatch_workers IN SHARE ROW EXCLUSIVE MODE;
-- 既有退款权威、集群身份、角色及窗口须吻合。配置文件不携带商户密钥；运行角色无权登记自己。
SELECT EXISTS(SELECT FROM meton_ledger.refund_gate_authorities a JOIN pg_roles r ON r.rolname=:'worker_role'
    WHERE (a.deployment,a.source,a.epoch,a.key_ref,a.inbox_system)=(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'inbox_system')
        AND meton_ledger.notification_system_id()=:'source_system' AND a.inbox_system<>:'source_system'
        AND :'cash_environment' IN ('isolated','live')
        AND NOT EXISTS(SELECT FROM meton_ledger.refund_dispatch_policies p WHERE
            (p.deployment,p.source,p.epoch)=(:'deployment',:'source',:'epoch'::bigint) AND
            (p.channel,p.cash_environment,p.merchant,p.app) IS DISTINCT FROM ('wechatpay',:'cash_environment',:'merchant',:'app'))
        AND r.rolcanlogin AND NOT (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)) AS valid_source \gset
\if :valid_source
\else
DO $$ BEGIN RAISE EXCEPTION 'original source, key or worker role differs'; END $$;
\endif
INSERT INTO meton_ledger.refund_dispatch_policies VALUES(:'deployment',:'source',:'epoch'::bigint,'wechatpay',:'cash_environment',:'merchant',:'app',
    :'send_seconds'::integer,:'query_seconds'::integer) ON CONFLICT DO NOTHING;
INSERT INTO meton_ledger.refund_dispatch_workers VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'worker_role') ON CONFLICT DO NOTHING;
SELECT EXISTS(SELECT FROM meton_ledger.refund_dispatch_policies p JOIN meton_ledger.refund_dispatch_workers w USING(deployment,source,epoch)
    WHERE (p.deployment,p.source,p.epoch,p.channel,p.cash_environment,p.merchant,p.app,p.send_seconds,p.query_seconds,w.key_ref,w.worker_role)=
        (:'deployment',:'source',:'epoch'::bigint,'wechatpay',:'cash_environment',:'merchant',:'app',:'send_seconds'::integer,:'query_seconds'::integer,:'key_ref'::uuid,:'worker_role'::name))
    AS original_policy \gset
\if :original_policy
GRANT USAGE ON SCHEMA meton_ledger TO :"worker_role";
GRANT EXECUTE ON FUNCTION meton_ledger.notification_system_id(),meton_ledger.refund_dispatch_ready(jsonb),meton_ledger.claim_original_refund_work(jsonb),
    meton_ledger.mark_original_refund_dispatch(jsonb,uuid,uuid,jsonb),meton_ledger.original_refund_io_permit(jsonb,uuid,uuid,jsonb),
    meton_ledger.finish_original_refund_work(jsonb,uuid,uuid,text),meton_ledger.claim_recovered_refund_query(jsonb),
    meton_ledger.finish_recovered_refund_query(jsonb,uuid,uuid,text) TO :"worker_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'existing source policy, window or retired role differs'; END $$;
\endif
COMMIT;
