\set ON_ERROR_STOP on
BEGIN;
-- 先登记责任引用；生产负责人由运营任务另定，脚本没有测试角色默认值，也不授予普通账号或表写权限。
INSERT INTO meton_ledger.cash_closure_aftercare_policies(deployment,source,epoch,responsible_ref)
    VALUES(:'deployment',:'source',:'epoch'::bigint,:'responsible_ref') ON CONFLICT DO NOTHING;
SELECT count(*)=1 AND bool_and(responsible_ref=:'responsible_ref') AS original
    FROM meton_ledger.cash_closure_aftercare_policies WHERE
    (deployment,source,epoch)=(:'deployment',:'source',:'epoch'::bigint) \gset
\if :original
\else
DO $$ BEGIN RAISE EXCEPTION 'original closure aftercare responsibility differs'; END $$;
\endif
COMMIT;
