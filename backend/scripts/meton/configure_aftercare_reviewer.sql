\set ON_ERROR_STOP on
-- 兼容已有隔离配置；真实现金必须显式指定，禁止由错误或空值推定。
\if :{?cash_environment}
\else
\set cash_environment isolated
\endif
BEGIN;
-- 当前只装配隔离测试审核员。实际运营入口与人员权限仍归 S3-23，不给收银台或会员角色这项能力。
SELECT EXISTS(SELECT FROM meton_inbox.refund_gate_authorities a JOIN pg_roles r ON r.rolname=:'reviewer_role'
    JOIN meton_inbox.writers w ON (w.deployment,w.source_name,w.generation,w.source_system)=(a.deployment,a.source,a.epoch,a.source_system)
    WHERE (a.deployment,a.source,a.epoch,a.key_ref)=(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid)
        AND w.cash_environment=:'cash_environment' AND :'cash_environment' IN ('isolated','live') AND a.source_system=:'source_system' AND meton_inbox.system_id()=:'inbox_system'
        AND :'source_system'<>:'inbox_system' AND r.rolname NOT IN (a.sender,a.stopper,w.writer)
        AND NOT EXISTS(SELECT FROM meton_inbox.refund_resolution_roles s WHERE s.resolver=r.rolname)
        AND r.rolcanlogin AND NOT (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)) AS eligible \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'current original payer reviewer required'; END $$;
\endif
INSERT INTO meton_inbox.refund_aftercare_review_roles VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'reviewer_role') ON CONFLICT DO NOTHING;
SELECT EXISTS(SELECT FROM meton_inbox.refund_aftercare_review_roles WHERE (deployment,source,epoch,key_ref,reviewer)=
    (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'reviewer_role'::name)) AS original \gset
\if :original
GRANT USAGE ON SCHEMA meton_inbox TO :"reviewer_role";
GRANT EXECUTE ON FUNCTION meton_inbox.record_original_payer_review(jsonb,uuid,uuid,jsonb,text,bytea),
    meton_inbox.cash_dispute_submission_material(jsonb,uuid,uuid),
    meton_inbox.cash_dispute_review_context(jsonb,uuid),meton_inbox.record_cash_dispute_review(jsonb,uuid,uuid,jsonb,text,bytea),
    meton_inbox.record_original_alternative_approval(jsonb,uuid,uuid,jsonb,text,bytea) TO :"reviewer_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'aftercare reviewer generation already registered'; END $$;
\endif
COMMIT;
