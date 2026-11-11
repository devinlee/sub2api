\set ON_ERROR_STOP on
BEGIN;
-- HTTP 确认和只读回执只执行自己的鉴权包装，不能直接调用原范围函数。
CREATE TEMP TABLE closure_scope_setup(purpose text,actor name) ON COMMIT DROP;
INSERT INTO closure_scope_setup VALUES('bind',:'bind_role'),('read',:'read_role');
SELECT count(DISTINCT s.actor)=2 AND bool_and(r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)
    AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
    AND NOT has_schema_privilege(r.oid,'meton_ledger','CREATE')
    AND NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p')
        AND (has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
    AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_ledger' AND p.prosecdef
        AND p.proname NOT IN ('notification_system_id',CASE WHEN s.purpose='bind' THEN 'http_checkout_closure_bind' ELSE 'http_checkout_closure_scope' END)
        AND has_function_privilege(r.oid,p.oid,'EXECUTE'))
    AND EXISTS(SELECT FROM public.meton_managed_fence f WHERE f.singleton AND f.enabled AND
        (f.environment,f.source,f.epoch)=(:'deployment',:'source',:'epoch'::bigint))) AS eligible
    FROM closure_scope_setup s JOIN pg_roles r ON r.rolname=s.actor \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate current closure scope roles required'; END $$;
\endif
INSERT INTO meton_ledger.cash_closure_scope_roles SELECT :'deployment',:'source',:'epoch'::bigint,actor,purpose FROM closure_scope_setup ON CONFLICT DO NOTHING;
INSERT INTO meton_ledger.cash_closure_readers SELECT :'deployment',:'source',:'epoch'::bigint,actor FROM closure_scope_setup WHERE purpose='bind' ON CONFLICT DO NOTHING;
SELECT count(*)=2 AND bool_and((r.deployment,r.source,r.epoch,r.purpose)=(:'deployment',:'source',:'epoch'::bigint,s.purpose))
    AND EXISTS(SELECT FROM meton_ledger.cash_closure_readers c WHERE (c.deployment,c.source,c.epoch,c.reader)=
        (:'deployment',:'source',:'epoch'::bigint,:'bind_role'::name)) AS original
    FROM closure_scope_setup s JOIN meton_ledger.cash_closure_scope_roles r USING(actor) \gset
\if :original
SELECT format('ALTER ROLE %I SET statement_timeout=''5s''; ALTER ROLE %I SET lock_timeout=''1s''; ALTER ROLE %I SET idle_in_transaction_session_timeout=''10s''; GRANT USAGE ON SCHEMA meton_ledger TO %I; GRANT EXECUTE ON FUNCTION meton_ledger.%s,meton_ledger.notification_system_id() TO %I',
    actor,actor,actor,actor,CASE WHEN purpose='bind' THEN 'http_checkout_closure_bind(text,text,bigint,timestamptz,bigint,text)' ELSE 'http_checkout_closure_scope(text,text,bigint,timestamptz,bigint,text)' END,actor)
    FROM closure_scope_setup \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'closure scope role belongs to another purpose or generation'; END $$;
\endif
COMMIT;
