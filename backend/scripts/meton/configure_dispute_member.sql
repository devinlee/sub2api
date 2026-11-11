\set ON_ERROR_STOP on
BEGIN;
-- 会员材料桥接身份不兼任付款、通知收件、结清或审核。这里只登记当前原权威的一项用途。
SELECT EXISTS(SELECT FROM meton_inbox.refund_gate_authorities a JOIN pg_roles r ON r.rolname=:'member_role'
    WHERE (a.deployment,a.source,a.epoch,a.key_ref)=(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid)
        AND a.source_system=:'source_system' AND meton_inbox.system_id()=:'inbox_system' AND :'source_system'<>:'inbox_system'
        AND r.rolname NOT IN (a.sender,a.stopper) AND r.rolcanlogin AND NOT(r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls)
        AND NOT EXISTS(SELECT FROM meton_inbox.writers WHERE writer=r.rolname)
        AND NOT EXISTS(SELECT FROM meton_inbox.refund_resolution_roles WHERE resolver=r.rolname)
        AND NOT EXISTS(SELECT FROM meton_inbox.refund_aftercare_review_roles WHERE reviewer=r.rolname)) AS eligible \gset
\if :eligible
\else
DO $$ BEGIN RAISE EXCEPTION 'separate member dispute role required'; END $$;
\endif
INSERT INTO meton_inbox.cash_dispute_member_roles VALUES(:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'member_role') ON CONFLICT DO NOTHING;
SELECT EXISTS(SELECT FROM meton_inbox.cash_dispute_member_roles WHERE (deployment,source,epoch,key_ref,member_role)=
    (:'deployment',:'source',:'epoch'::bigint,:'key_ref'::uuid,:'member_role'::name)) AS original \gset
\if :original
GRANT USAGE ON SCHEMA meton_inbox TO :"member_role";
GRANT EXECUTE ON FUNCTION meton_inbox.system_id(),meton_inbox.member_cash_dispute(jsonb,text,bytea) TO :"member_role";
\else
DO $$ BEGIN RAISE EXCEPTION 'member dispute role generation already registered'; END $$;
\endif
COMMIT;
