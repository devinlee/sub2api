\set ON_ERROR_STOP on
BEGIN;
LOCK TABLE meton_inbox.refund_gate_authorities,meton_inbox.writers IN SHARE MODE;
-- 明确授予商户范围，而不是无法从未解密回执证明的某个应用／账号范围；旧身份不能换代重新登记。
SELECT count(*)=1 AND bool_and(r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)
    AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
    AND NOT has_schema_privilege(r.oid,'meton_inbox','CREATE')
    AND NOT EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
        (has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
    AND NOT EXISTS(SELECT FROM pg_proc p WHERE p.pronamespace='meton_inbox'::regnamespace AND p.prosecdef AND
        p.oid NOT IN ('meton_inbox.read_cash_archive_operations(jsonb,text,integer)'::regprocedure,'meton_inbox.read_cash_archive_operation(jsonb,text)'::regprocedure,'meton_inbox.read_cash_archive_link(jsonb,text)'::regprocedure) AND has_function_privilege(r.oid,p.oid,'EXECUTE'))
    AND EXISTS(SELECT FROM meton_inbox.refund_gate_authorities a WHERE
        (a.deployment,a.source,a.epoch,a.key_ref,a.source_system)=(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'source_system')
        AND a.source_system<>meton_inbox.system_id())
    AND EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(:'channel',:'cash_environment',:'merchant'))
    AND NOT EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.channel,w.cash_environment,w.merchant)=(:'channel',:'cash_environment',:'merchant') AND
        (w.deployment,w.source_name,w.generation,w.source_system)<>(:'deployment',:'source',:'epoch'::bigint,:'source_system'))) AS eligible
    FROM pg_roles r WHERE r.rolname=:'read_role' \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate current merchant archive reader required'; END $$;
\endif
INSERT INTO meton_inbox.cash_archive_readers VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'source_system',
    :'channel',:'cash_environment',:'merchant',:'read_role') ON CONFLICT DO NOTHING;
SELECT count(*)=1 AND bool_and((deployment,source,epoch,key_ref,source_system,channel,cash_environment,merchant)=
    (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'source_system',:'channel',:'cash_environment',:'merchant')) AS original
    FROM meton_inbox.cash_archive_readers WHERE reader=:'read_role' \gset
\if :original
SELECT format('ALTER ROLE %I SET statement_timeout=''5s'';ALTER ROLE %I SET lock_timeout=''1s'';ALTER ROLE %I SET idle_in_transaction_session_timeout=''10s'';GRANT USAGE ON SCHEMA meton_inbox TO %I;GRANT EXECUTE ON FUNCTION meton_inbox.read_cash_archive_operations(jsonb,text,integer),meton_inbox.read_cash_archive_operation(jsonb,text),meton_inbox.read_cash_archive_link(jsonb,text) TO %I',
    :'read_role',:'read_role',:'read_role',:'read_role',:'read_role') \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'archive reader belongs to another scope or generation'; END $$;
\endif
COMMIT;
