\set ON_ERROR_STOP on
BEGIN;
-- 只允许为这三项原范围命令配置独立角色；不得共享来源表、普通退款或其他注销用途。
CREATE TEMP TABLE closure_refund_setup(purpose text,actor name,command text) ON COMMIT DROP;
INSERT INTO closure_refund_setup VALUES
    ('admit',:'admit_role','admit_cash_closure_refund(jsonb,uuid,uuid,text,jsonb,uuid,bigint,uuid,uuid,text,timestamptz)'),
    ('stop',:'stop_role','stop_cash_closure_refunds(jsonb,uuid,uuid,text,jsonb,timestamptz)'),
    ('read',:'read_role','read_cash_closure_refunds(jsonb,uuid,uuid,text,bigint,int)');
SELECT count(DISTINCT s.actor)=3 AND bool_and(r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls OR r.rolinherit)
    AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=r.oid)
    AND NOT has_schema_privilege(r.oid,'meton_ledger','CREATE')
    AND NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p')
        AND (has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
    AND NOT EXISTS(SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='meton_ledger' AND p.prosecdef
        AND p.oid<>('meton_ledger.'||s.command)::regprocedure AND has_function_privilege(r.oid,p.oid,'EXECUTE')))
    AS safe FROM closure_refund_setup s JOIN pg_roles r ON r.rolname=s.actor \gset
\if :safe
\else
DO $$ BEGIN RAISE EXCEPTION 'separate restricted closure refund roles required'; END $$;
\endif
INSERT INTO meton_ledger.cash_closure_refund_roles SELECT :'deployment',:'source',:'epoch'::bigint,actor,purpose FROM closure_refund_setup ON CONFLICT DO NOTHING;
SELECT count(*)=3 AND bool_and((r.deployment,r.source,r.epoch,r.purpose)=(:'deployment',:'source',:'epoch'::bigint,s.purpose)) AS original
    FROM closure_refund_setup s JOIN meton_ledger.cash_closure_refund_roles r USING(actor) \gset
\if :original
SELECT format('ALTER ROLE %I SET statement_timeout=''5s''; ALTER ROLE %I SET lock_timeout=''1s''; ALTER ROLE %I SET idle_in_transaction_session_timeout=''10s''; GRANT USAGE ON SCHEMA meton_ledger TO %I; GRANT EXECUTE ON FUNCTION meton_ledger.%s TO %I',
    actor,actor,actor,actor,command,actor) FROM closure_refund_setup \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'closure refund role belongs to another purpose or generation'; END $$;
\endif
COMMIT;
