\set ON_ERROR_STOP on
BEGIN;
-- 与原资金执行身份分离。恢复换代使用新角色，旧角色即使知道当前代次也不能读回新材料。
SELECT EXISTS(SELECT FROM public.meton_managed_fence f JOIN pg_roles r ON r.rolname=:'reader_role'
    WHERE f.singleton AND f.enabled AND (f.environment,f.source,f.epoch)=(:'deployment',:'source',:'epoch'::bigint)
      AND r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)
      AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
      AND NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p')
          AND (has_table_privilege(r.oid,c.oid,'SELECT') OR has_any_column_privilege(r.oid,c.oid,'SELECT')))
      AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_ledger' AND p.prosecdef
        AND p.proname NOT IN ('open_cash_closure_snapshot','read_cash_closure_snapshot') AND has_function_privilege(r.oid,p.oid,'EXECUTE'))
      AND NOT has_table_privilege(r.oid,'public.users','UPDATE')
      AND NOT has_table_privilege(r.oid,'meton_ledger.cash_refunds','INSERT,UPDATE,DELETE')) AS eligible \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate closure reader required'; END $$;
\endif
INSERT INTO meton_ledger.cash_closure_readers VALUES(:'deployment',:'source',:'epoch'::bigint,:'reader_role') ON CONFLICT DO NOTHING;
SELECT EXISTS(SELECT FROM meton_ledger.cash_closure_readers WHERE (deployment,source,epoch,reader)=
    (:'deployment',:'source',:'epoch'::bigint,:'reader_role'::name)) AS current_reader \gset
\if :current_reader
ALTER ROLE :"reader_role" SET statement_timeout='5s';
ALTER ROLE :"reader_role" SET lock_timeout='1s';
ALTER ROLE :"reader_role" SET idle_in_transaction_session_timeout='10s';
GRANT USAGE ON SCHEMA meton_ledger TO :"reader_role";
GRANT EXECUTE ON FUNCTION meton_ledger.open_cash_closure_snapshot(jsonb,uuid,uuid,jsonb,timestamptz),
    meton_ledger.read_cash_closure_snapshot(jsonb,uuid,uuid,jsonb,integer,integer) TO :"reader_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'closure reader already belongs to another generation'; END $$;
\endif
COMMIT;
