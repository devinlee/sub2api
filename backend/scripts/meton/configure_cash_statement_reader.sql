\set ON_ERROR_STOP on
BEGIN;
-- 只为独立读取角色登记三个窄函数。不会创建角色、迁移、修改资金或剥夺其他角色的权限。
SELECT EXISTS(SELECT FROM public.meton_managed_fence f JOIN pg_roles r ON r.rolname=:'reader_role'
    WHERE f.singleton AND f.enabled AND (f.environment,f.source,f.epoch)=(:'deployment',:'source',:'epoch'::bigint)
      AND r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)
      AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
      AND NOT has_schema_privilege(r.oid,'public','CREATE') AND NOT has_schema_privilege(r.oid,'meton_ledger','CREATE')
      AND NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger')
        AND c.relkind IN ('r','p') AND (has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER')
        OR has_any_column_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE')))
      AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_ledger'
        AND p.oid<>ALL(ARRAY['meton_ledger.open_statement(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,date,date)'::regprocedure,
            'meton_ledger.read_statement_page(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,date,date,bigint,uuid,bigint,integer)'::regprocedure,
            'meton_ledger.read_cash_statement(jsonb,jsonb,date,date,text,bigint,integer)'::regprocedure]::oid[])
        AND has_function_privilege(r.oid,p.oid,'EXECUTE'))
      AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
        AND (p.proname IN ('meton_claim_managed_account','meton_issue_managed_key','meton_close_original_session','meton_recover_original')
            OR p.proname LIKE 'meton_retire_key_for_rotation%') AND has_function_privilege(r.oid,p.oid,'EXECUTE'))) AS eligible \gset
\if :eligible
ALTER ROLE :"reader_role" SET statement_timeout='5s';
ALTER ROLE :"reader_role" SET lock_timeout='1s';
ALTER ROLE :"reader_role" SET idle_in_transaction_session_timeout='10s';
GRANT USAGE ON SCHEMA meton_ledger TO :"reader_role";
GRANT EXECUTE ON FUNCTION meton_ledger.open_statement(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,date,date),
    meton_ledger.read_statement_page(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,date,date,bigint,uuid,bigint,integer),
    meton_ledger.read_cash_statement(jsonb,jsonb,date,date,text,bigint,integer) TO :"reader_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'separate current cash statement reader required'; END $$;
\endif
COMMIT;
