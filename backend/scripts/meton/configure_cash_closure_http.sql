\set ON_ERROR_STOP on
BEGIN;
-- 两种 HTTP 身份只执行自己的固定鉴权入口；不同时授予裸快照函数、其他渠道或资金权限。
CREATE TEMP TABLE closure_http_setup(action text,reader name) ON COMMIT DROP;
INSERT INTO closure_http_setup VALUES('closure_open',:'open_role'),('closure_page',:'page_role');
SELECT count(DISTINCT s.reader)=2 AND bool_and(r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)
    AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
    AND NOT has_schema_privilege(r.oid,'meton_ledger','CREATE')
    AND NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p')
        AND (has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
    AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_ledger' AND p.prosecdef
        AND p.proname NOT IN ('http_checkout_'||s.action,'notification_system_id') AND has_function_privilege(r.oid,p.oid,'EXECUTE'))
    AND EXISTS(SELECT FROM public.meton_managed_fence f WHERE f.singleton AND f.enabled AND
        (f.environment,f.source,f.epoch)=(:'deployment',:'source',:'epoch'::bigint))) AS eligible
    FROM closure_http_setup s JOIN pg_roles r ON r.rolname=s.reader \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate current closure HTTP roles required'; END $$;
\endif
INSERT INTO meton_ledger.cash_closure_readers SELECT :'deployment',:'source',:'epoch'::bigint,reader FROM closure_http_setup ON CONFLICT DO NOTHING;
SELECT count(*)=2 AS original FROM closure_http_setup s JOIN meton_ledger.cash_closure_readers r USING(reader)
    WHERE (r.deployment,r.source,r.epoch)=(:'deployment',:'source',:'epoch'::bigint) \gset
\if :original
SELECT format('ALTER ROLE %I SET statement_timeout=''5s''; ALTER ROLE %I SET lock_timeout=''1s''; ALTER ROLE %I SET idle_in_transaction_session_timeout=''10s''; GRANT USAGE ON SCHEMA meton_ledger TO %I; GRANT EXECUTE ON FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text),meton_ledger.notification_system_id() TO %I',
    reader,reader,reader,reader,'http_checkout_'||action,reader) FROM closure_http_setup \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'closure HTTP role belongs to another generation'; END $$;
\endif
COMMIT;
