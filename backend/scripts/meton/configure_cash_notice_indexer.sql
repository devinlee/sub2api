\set ON_ERROR_STOP on
BEGIN;
LOCK TABLE meton_inbox.writers,meton_inbox.cash_notice_indexers IN SHARE MODE;
SELECT count(*)=1 AND bool_and(p.rolcanlogin AND NOT(p.rolsuper OR p.rolinherit OR p.rolcreatedb OR p.rolcreaterole OR p.rolreplication OR p.rolbypassrls)
    AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member=p.oid)
    AND NOT has_schema_privilege(p.oid,'meton_inbox','CREATE') AND NOT has_schema_privilege(p.oid,'public','CREATE')
    AND NOT EXISTS(SELECT FROM pg_class c WHERE c.relnamespace='meton_inbox'::regnamespace AND c.relkind IN ('r','p') AND
        (has_table_privilege(p.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(p.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
    AND NOT EXISTS(SELECT FROM pg_proc f WHERE f.pronamespace='meton_inbox'::regnamespace AND f.oid NOT IN
        ('meton_inbox.system_id()'::regprocedure,'meton_inbox.lock_cash_notice_indexer(jsonb)'::regprocedure,
         'meton_inbox.claim_cash_notice_origin(jsonb)'::regprocedure,'meton_inbox.read_cash_notice_origin(jsonb,uuid,bytea,uuid)'::regprocedure,
         'meton_inbox.finish_cash_notice_origin(jsonb,uuid,bytea,uuid,text,text,bytea)'::regprocedure) AND has_function_privilege(p.oid,f.oid,'EXECUTE'))
    AND EXISTS(SELECT FROM meton_inbox.writers w WHERE (w.deployment,w.source_name,w.generation,w.source_system,w.channel,w.cash_environment,w.merchant,w.app)=
        (:'deployment',:'source',:'epoch'::bigint,:'source_system',:'channel',:'cash_environment',:'merchant',:'app') AND w.writer<>p.rolname
        AND w.source_system<>meton_inbox.system_id())) AS eligible FROM pg_roles p WHERE p.rolname=:'index_role' \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate current notice indexer required'; END $$;
\endif
INSERT INTO meton_inbox.cash_notice_indexers VALUES(:'deployment',:'source',:'epoch'::bigint,:'source_system',:'channel',:'cash_environment',:'merchant',:'app',:'index_role')
    ON CONFLICT DO NOTHING;
SELECT count(*)=1 AND bool_and((deployment,source,epoch,source_system,channel,cash_environment,merchant,app)=
    (:'deployment',:'source',:'epoch'::bigint,:'source_system',:'channel',:'cash_environment',:'merchant',:'app')) AS original
    FROM meton_inbox.cash_notice_indexers WHERE indexer=:'index_role' \gset
\if :original
SELECT format('ALTER ROLE %I SET statement_timeout=''5s'';ALTER ROLE %I SET lock_timeout=''1s'';ALTER ROLE %I SET idle_in_transaction_session_timeout=''10s'';GRANT USAGE ON SCHEMA meton_inbox TO %I;GRANT EXECUTE ON FUNCTION meton_inbox.system_id(),meton_inbox.lock_cash_notice_indexer(jsonb),meton_inbox.claim_cash_notice_origin(jsonb),meton_inbox.read_cash_notice_origin(jsonb,uuid,bytea,uuid),meton_inbox.finish_cash_notice_origin(jsonb,uuid,bytea,uuid,text,text,bytea) TO %I',
    :'index_role',:'index_role',:'index_role',:'index_role',:'index_role') \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'notice indexer belongs to another original scope'; END $$;
\endif
COMMIT;
