\set ON_ERROR_STOP on
BEGIN;
LOCK TABLE meton_inbox.writers,meton_inbox.refund_gate_authorities,meton_inbox.refund_aftercare_review_roles,meton_inbox.cash_review_controllers IN SHARE MODE;
-- 不覆盖这一代已登记的旧审核角色。更换服务身份须按原换代协议配置，不能撤销保护触发器改表。
SELECT count(*)=1 AND bool_and(p.rolcanlogin AND NOT(p.rolsuper OR p.rolinherit OR p.rolcreatedb OR p.rolcreaterole OR p.rolreplication OR p.rolbypassrls)
    AND :'cash_environment' IN ('isolated','live') AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=p.oid)
    AND NOT has_schema_privilege(p.oid,'meton_inbox','CREATE') AND NOT has_schema_privilege(p.oid,'public','CREATE')
    AND NOT EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
        (has_table_privilege(p.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(p.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
    AND NOT EXISTS(SELECT FROM pg_proc f WHERE f.pronamespace='meton_inbox'::regnamespace AND f.oid NOT IN
        ('meton_inbox.system_id()'::regprocedure,'meton_inbox.cash_manual_review_ready(jsonb)'::regprocedure,
         'meton_inbox.cash_manual_review_context(jsonb,text)'::regprocedure,'meton_inbox.cash_manual_review(jsonb,jsonb,text,bytea,text)'::regprocedure)
        AND has_function_privilege(p.oid,f.oid,'EXECUTE'))
    AND EXISTS(SELECT FROM meton_inbox.refund_gate_authorities a WHERE (a.deployment,a.source,a.epoch,a.key_ref,a.source_system)=
        (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'source_system') AND a.source_system<>meton_inbox.system_id()
        AND p.rolname NOT IN (a.sender,a.stopper))
    AND NOT EXISTS(SELECT FROM meton_inbox.refund_resolution_roles r WHERE r.resolver=p.rolname)
    AND NOT EXISTS(SELECT FROM meton_inbox.refund_aftercare_review_roles r WHERE (r.deployment,r.source,r.epoch,r.key_ref)=
        (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid) AND r.reviewer<>p.rolname)
    AND EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(:'channel',:'cash_environment',:'merchant'))
    AND NOT EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(:'channel',:'cash_environment',:'merchant') AND
        ((w.deployment,w.source_name,w.generation,w.source_system)<>(:'deployment',:'source',:'epoch'::bigint,:'source_system') OR w.writer=p.rolname)))
    AS eligible FROM pg_roles p WHERE p.rolname=:'control_role' \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate current original review controller required'; END $$;
\endif
INSERT INTO meton_inbox.refund_aftercare_review_roles VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'control_role') ON CONFLICT DO NOTHING;
INSERT INTO meton_inbox.cash_review_controllers VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'source_system',
    :'channel',:'cash_environment',:'merchant',:'control_role') ON CONFLICT DO NOTHING;
SELECT count(*)=1 AND bool_and((deployment,source,epoch,key_ref,source_system,channel,cash_environment,merchant)=
    (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'source_system',:'channel',:'cash_environment',:'merchant')) AS original
    FROM meton_inbox.cash_review_controllers WHERE controller=:'control_role' \gset
\if :original
SELECT format('ALTER ROLE %I SET statement_timeout=''5s'';ALTER ROLE %I SET lock_timeout=''1s'';ALTER ROLE %I SET idle_in_transaction_session_timeout=''10s'';GRANT USAGE ON SCHEMA meton_inbox TO %I;GRANT EXECUTE ON FUNCTION meton_inbox.system_id(),meton_inbox.cash_manual_review_ready(jsonb),meton_inbox.cash_manual_review_context(jsonb,text),meton_inbox.cash_manual_review(jsonb,jsonb,text,bytea,text) TO %I',
    :'control_role',:'control_role',:'control_role',:'control_role',:'control_role') \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'cash review controller belongs to another original scope'; END $$;
\endif
COMMIT;
