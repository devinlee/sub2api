-- 截点外已经决定的替代退款可以重建原记录，不能凭恢复重新分配本金、赠送或现金发送权。
CREATE TABLE meton_ledger.refund_alternative_recoveries(
    refund uuid NOT NULL REFERENCES meton_ledger.refund_alternative_intents,
    epoch bigint NOT NULL, key_ref uuid NOT NULL, ticket uuid NOT NULL,
    evidence bytea NOT NULL CHECK(octet_length(evidence)=32), aftercare_rebuilt boolean NOT NULL,
    recovered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(refund,epoch,key_ref)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_alternative_recoveries
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_alternative_recoveries ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_alternative_recoveries FROM PUBLIC;

/** 当前独立决定证明原来源曾准备同一份额。恢复只补原记录，现金终态仍由原结清器单独处理。 */
CREATE OR REPLACE FUNCTION meton_ledger.apply_original_alternative_decision(route jsonb,ref uuid,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    i meton_ledger.refund_alternative_intents;d meton_ledger.refund_alternative_decisions;c meton_ledger.refund_aftercare_cases;
    f jsonb:=proof->'facts';p jsonb:=f->'proposal';s jsonb;rebuild boolean;case_missing boolean;digest bytea;
BEGIN
    IF context IS NULL THEN RETURN 'recovery_review'; END IF;
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF proof->>'state' IS DISTINCT FROM 'decision_proved' OR f->'scope' IS DISTINCT FROM s OR p->'envelope' IS DISTINCT FROM context->'envelope' OR
        f#>'{aftercare,envelope}' IS DISTINCT FROM context->'envelope' OR
        ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds' AND
            f->>'choice' IN ('reserved','abandoned') AND (f->>'ticket')::uuid IS NOT NULL AND
            f#>>'{aftercare,reason}' IN ('window_elapsed','payer_account_unavailable') AND p->>'format'='1' AND
            p->>'refund'=ref::text AND p->>'intent'=context->>'intent' AND p#>>'{payment,fen}'=context->>'fen' AND
            p#>>'{payment,rail}'='meton-isolated-transfer' AND p#>>'{payment,environment}'='isolated' AND p#>>'{payment,currency}'='CNY') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.alternative.decided.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified alternative decision' USING ERRCODE='42501'; END IF;
    SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    SELECT * INTO c FROM meton_ledger.refund_aftercare_cases WHERE refund=ref;
    rebuild:=i.refund IS NULL;case_missing:=c.refund IS NULL;digest:=sha256(convert_to(p::text,'UTF8'));
    IF i.refund IS NOT NULL AND (i.proposal,i.digest) IS DISTINCT FROM (p,digest) THEN RETURN 'recovery_review'; END IF;
    IF c.refund IS NOT NULL AND (c.marker,c.intent,c.envelope,c.reason) IS DISTINCT FROM
        ((context->>'marker')::uuid,(context->>'intent')::uuid,context->'envelope',f#>>'{aftercare,reason}') THEN RETURN 'recovery_review'; END IF;
    -- 原始开案时间未在早期独立材料中保存，重建时间单列；不把恢复时间伪装为原申请时间。
    INSERT INTO meton_ledger.refund_aftercare_cases(refund,marker,intent,envelope,reason,opened_epoch,opened_by)
        VALUES(ref,(context->>'marker')::uuid,(context->>'intent')::uuid,context->'envelope',f#>>'{aftercare,reason}',a.epoch,session_user) ON CONFLICT DO NOTHING;
    INSERT INTO meton_ledger.refund_alternative_intents(refund,proposal,digest) VALUES(ref,p,digest) ON CONFLICT DO NOTHING;
    INSERT INTO meton_ledger.refund_alternative_decisions VALUES(ref,f->>'choice',(f->>'ticket')::uuid,digest) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    IF (d.choice,d.ticket,d.digest) IS DISTINCT FROM (f->>'choice',(f->>'ticket')::uuid,digest) THEN RETURN 'recovery_review'; END IF;
    IF rebuild OR case_missing THEN
        INSERT INTO meton_ledger.refund_alternative_recoveries(refund,epoch,key_ref,ticket,evidence,aftercare_rebuilt)
            VALUES(ref,a.epoch,a.key_ref,d.ticket,sha256(convert_to((f-'validUntil')::text,'UTF8')),case_missing) ON CONFLICT DO NOTHING;
    END IF;
    RETURN d.choice;
END $$;

DO $view$
DECLARE body text:=pg_get_functiondef('meton_ledger.refund_aftercare_view(uuid,jsonb)'::regprocedure);
    point text:='SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative recovery projection changed'; END IF;
    EXECUTE replace(body,point,$new$IF EXISTS(SELECT FROM meton_ledger.refund_alternative_recoveries WHERE refund=ref AND aftercare_rebuilt) THEN
        out:=out||jsonb_build_object('openedAt',NULL,'recoveredAt',(SELECT min(recovered_at) FROM meton_ledger.refund_alternative_recoveries WHERE refund=ref AND aftercare_rebuilt));
    END IF; $new$||point);
END $view$;
