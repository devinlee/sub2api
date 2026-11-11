\set ON_ERROR_STOP on
BEGIN;
-- 角色一代一份，重复配置只接受原归属；旧数据库登录不能因换代配置再次获得当前读取权。
SELECT count(*)=1 AND bool_and(r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)
    AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
    AND NOT has_schema_privilege(r.oid,'meton_ledger','CREATE')
    AND NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p')
        AND (has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
    AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_ledger' AND p.prosecdef
        AND p.oid NOT IN ('meton_ledger.read_cash_operations(jsonb,text,integer)'::regprocedure,'meton_ledger.read_cash_operation(jsonb,text)'::regprocedure,'meton_ledger.read_cash_archive_original(jsonb,jsonb)'::regprocedure) AND has_function_privilege(r.oid,p.oid,'EXECUTE'))
    AND EXISTS(SELECT FROM public.meton_managed_fence f WHERE f.singleton AND f.enabled AND
        (f.environment,f.source,f.epoch)=(:'deployment',:'source',:'epoch'::bigint))) AS eligible
    FROM pg_roles r WHERE r.rolname=:'read_role' \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate current cash operations reader required'; END $$;
\endif
INSERT INTO meton_ledger.cash_operations_readers VALUES(:'deployment',:'source',:'epoch'::bigint,:'read_role') ON CONFLICT DO NOTHING;
SELECT count(*)=1 AND bool_and((deployment,source,epoch)=(:'deployment',:'source',:'epoch'::bigint)) AS original
    FROM meton_ledger.cash_operations_readers WHERE reader=:'read_role' \gset
\if :original
SELECT format('ALTER ROLE %I SET statement_timeout=''5s''; ALTER ROLE %I SET lock_timeout=''1s''; ALTER ROLE %I SET idle_in_transaction_session_timeout=''10s''; GRANT USAGE ON SCHEMA meton_ledger TO %I; GRANT EXECUTE ON FUNCTION meton_ledger.read_cash_operations(jsonb,text,integer),meton_ledger.read_cash_operation(jsonb,text),meton_ledger.read_cash_archive_original(jsonb,jsonb) TO %I',
    :'read_role',:'read_role',:'read_role',:'read_role',:'read_role') \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'cash operations reader belongs to another generation or source'; END $$;
\endif
COMMIT;
