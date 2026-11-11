-- 核验和替代决定都可证明截点外已有原售后。两条接回路径共用重建，未批准的原申请不能因此获得付款权。
CREATE TABLE meton_ledger.refund_aftercare_recoveries(
    refund uuid NOT NULL REFERENCES meton_ledger.refund_aftercare_cases,
    epoch bigint NOT NULL, key_ref uuid NOT NULL,
    evidence bytea NOT NULL CHECK(octet_length(evidence)=32),
    recovered_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(refund,epoch,key_ref)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_aftercare_recoveries
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_aftercare_recoveries ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_aftercare_recoveries FROM PUBLIC;

/** 调用方先完成原证明验签；这里只补同一原申请，不操作退款阶段或任何资金份额。 */
CREATE FUNCTION meton_ledger.restore_original_aftercare(context jsonb,ref uuid,original_reason text,
    authority meton_ledger.refund_gate_authorities,proof_hash bytea) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c meton_ledger.refund_aftercare_cases;
BEGIN
    IF context IS NULL OR (original_reason IN ('window_elapsed','payer_account_unavailable') AND octet_length(proof_hash)=32
        AND context#>>'{envelope,target,refund}'=ref::text AND (context->>'epoch')::bigint=authority.epoch) IS NOT TRUE THEN RETURN false; END IF;
    SELECT * INTO c FROM meton_ledger.refund_aftercare_cases WHERE refund=ref;
    IF FOUND THEN RETURN (c.marker,c.intent,c.envelope,c.reason) IS NOT DISTINCT FROM
        ((context->>'marker')::uuid,(context->>'intent')::uuid,context->'envelope',original_reason); END IF;
    INSERT INTO meton_ledger.refund_aftercare_cases(refund,marker,intent,envelope,reason,opened_epoch,opened_by)
        VALUES(ref,(context->>'marker')::uuid,(context->>'intent')::uuid,context->'envelope',original_reason,authority.epoch,session_user);
    INSERT INTO meton_ledger.refund_aftercare_recoveries(refund,epoch,key_ref,evidence)
        VALUES(ref,authority.epoch,authority.key_ref,proof_hash);
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.restore_original_aftercare(jsonb,uuid,text,meton_ledger.refund_gate_authorities,bytea) FROM PUBLIC;

DO $recover$
DECLARE body text:=pg_get_functiondef('meton_ledger.apply_original_refund_verification(jsonb,uuid,jsonb)'::regprocedure);point text;
BEGIN
    point:='IF context IS NULL OR NOT EXISTS(SELECT FROM meton_ledger.refund_aftercare_cases WHERE refund=ref) THEN';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'aftercare source prerequisite changed'; END IF;
    body:=replace(body,point,'IF context IS NULL THEN');
    point:='f->''envelope'' IS DISTINCT FROM context->''envelope'' OR';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'aftercare source proof changed'; END IF;
    body:=replace(body,point,point||' (f->>''reason'' IN (''window_elapsed'',''payer_account_unavailable'')) IS NOT TRUE OR');
    -- reason 由原申请及重建审计保存。旧核验行的同一 revision 不因签名增加交接字段变成冲突材料。
    point:='f-''validUntil''';
    IF cardinality(string_to_array(body,point))<>3 THEN RAISE EXCEPTION 'aftercare stored facts changed'; END IF;
    body:=replace(body,point,'f-ARRAY[''validUntil'',''reason'']');
    point:='rev:=(f->>''revision'')::bigint;';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'aftercare source revision changed'; END IF;
    EXECUTE replace(body,point,$new$IF NOT meton_ledger.restore_original_aftercare(context,ref,f->>'reason',a,
        sha256(convert_to((f-'validUntil')::text,'UTF8'))) THEN RETURN 'original_unavailable'; END IF; $new$||point);
    body:=pg_get_functiondef('meton_ledger.apply_original_alternative_decision(jsonb,uuid,jsonb)'::regprocedure);
    point:=$old$INSERT INTO meton_ledger.refund_aftercare_cases(refund,marker,intent,envelope,reason,opened_epoch,opened_by)
        VALUES(ref,(context->>'marker')::uuid,(context->>'intent')::uuid,context->'envelope',f#>>'{aftercare,reason}',a.epoch,session_user) ON CONFLICT DO NOTHING;$old$;
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative source recovery changed'; END IF;
    EXECUTE replace(body,point,$new$IF NOT meton_ledger.restore_original_aftercare(context,ref,f#>>'{aftercare,reason}',a,
        sha256(convert_to((f-'validUntil')::text,'UTF8'))) THEN RETURN 'recovery_review'; END IF;$new$);
    body:=pg_get_functiondef('meton_ledger.refund_aftercare_view(uuid,jsonb)'::regprocedure);
    point:='SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'aftercare recovery projection changed'; END IF;
    EXECUTE replace(body,point,$new$IF EXISTS(SELECT FROM meton_ledger.refund_aftercare_recoveries WHERE refund=ref) THEN
        out:=out||jsonb_build_object('openedAt',NULL,'recoveredAt',(SELECT min(recovered_at) FROM meton_ledger.refund_aftercare_recoveries WHERE refund=ref));
    END IF; $new$||point);
END $recover$;
