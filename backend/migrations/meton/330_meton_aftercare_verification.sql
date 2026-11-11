-- 核验结论来自截点外的原售后材料；来源只保存投影，不用核验结论直接改金额、冻结或现金状态。
CREATE TABLE meton_ledger.refund_aftercare_verifications(
    refund uuid NOT NULL REFERENCES meton_ledger.refund_aftercare_cases,
    epoch bigint NOT NULL CHECK(epoch>0), revision bigint NOT NULL CHECK(revision>0),
    facts jsonb NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(refund,epoch,revision)
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.refund_aftercare_verifications
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.refund_aftercare_verifications ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_ledger.refund_aftercare_verifications FROM PUBLIC;

/** 短期交接只能读取已受理的原售后；恢复后签发新代次，不改原付款人、退款号或份额。 */
CREATE FUNCTION meton_ledger.prepare_original_refund_aftercare(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route); c meton_ledger.refund_aftercare_cases; facts jsonb;
BEGIN
    SELECT * INTO c FROM meton_ledger.refund_aftercare_cases WHERE refund=ref;
    IF context IS NULL OR c.refund IS NULL THEN RETURN jsonb_build_object('state','not_opened'); END IF;
    IF c.envelope IS DISTINCT FROM context->'envelope' THEN RETURN jsonb_build_object('state','recovery_review'); END IF;
    IF context->>'phase' IN ('settled','released','cash_confirmed') THEN RETURN jsonb_build_object('state','original_terminal'); END IF;
    facts:=jsonb_build_object('format',1,'scope',jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,
        'keyRef',a.key_ref,'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system),
        'envelope',c.envelope,'reason',c.reason,'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','ready','facts',facts,'mac',encode(meton_ledger.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.aftercare.origin.v1',facts)::text,'UTF8'),a.seal_key),'hex'));
END $$;

/** 原结清进程在独立归档锁内交回已提交的核验事实。旧代次、错原单和旧版本不能覆盖新结论。 */
CREATE FUNCTION meton_ledger.apply_original_refund_verification(route jsonb,ref uuid,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE context jsonb:=meton_ledger.original_refund_aftercare_context(route,ref);
    a meton_ledger.refund_gate_authorities:=meton_ledger.require_cash_review_resolver(route);
    f jsonb:=proof->'facts'; s jsonb; saved jsonb; rev bigint;
BEGIN
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',route->>'sourceSystem','inboxSystem',a.inbox_system);
    IF context IS NULL OR NOT EXISTS(SELECT FROM meton_ledger.refund_aftercare_cases WHERE refund=ref) THEN RETURN 'original_unavailable'; END IF;
    IF proof->>'state' IS DISTINCT FROM 'verification_proved' OR f->>'format' IS DISTINCT FROM '1' OR f->'scope' IS DISTINCT FROM s OR
        f->'envelope' IS DISTINCT FROM context->'envelope' OR ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        ((f->>'revision')::bigint>0 AND f->>'evidenceHash'~'^[0-9a-f]{64}$'
        AND f#>>'{verification,payerState}' IN ('unverified','verified','rejected','review')
        AND f#>>'{verification,channelState}' IN ('unknown','pending','closed_unpaid','original_paid','review')) IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_ledger.refund_seal_mac(convert_to(jsonb_build_array('meton.refund.aftercare.verified.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'unverified original aftercare result' USING ERRCODE='42501'; END IF;
    rev:=(f->>'revision')::bigint;
    IF EXISTS(SELECT FROM meton_ledger.refund_aftercare_verifications WHERE refund=ref AND epoch=a.epoch AND revision>rev) THEN RETURN 'superseded'; END IF;
    INSERT INTO meton_ledger.refund_aftercare_verifications(refund,epoch,revision,facts) VALUES(ref,a.epoch,rev,f-'validUntil') ON CONFLICT DO NOTHING;
    SELECT facts INTO STRICT saved FROM meton_ledger.refund_aftercare_verifications WHERE refund=ref AND epoch=a.epoch AND revision=rev;
    IF saved IS DISTINCT FROM f-'validUntil' THEN RAISE EXCEPTION 'original aftercare result changed' USING ERRCODE='42501'; END IF;
    RETURN 'recorded';
END $$;

-- 原状态判定仍由 329 执行；新增只读核验投影不会把批准或付款伪装成核验完成。
ALTER FUNCTION meton_ledger.refund_aftercare_view(uuid,jsonb) RENAME TO refund_aftercare_admission_view;
CREATE FUNCTION meton_ledger.refund_aftercare_view(ref uuid,context jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE out jsonb:=meton_ledger.refund_aftercare_admission_view(ref,context); f jsonb;
BEGIN
    SELECT facts INTO f FROM meton_ledger.refund_aftercare_verifications
        WHERE refund=ref AND epoch=(context->>'epoch')::bigint ORDER BY revision DESC LIMIT 1;
    IF f IS NULL THEN RETURN out||jsonb_build_object('payerState','unverified','channelState','unknown'); END IF;
    RETURN out||jsonb_build_object('payerVerified',f#>>'{verification,payerState}'='verified','payerState',f#>'{verification,payerState}',
        'channelState',f#>'{verification,channelState}','verificationRevision',f->'revision');
END $$;
-- SQL 函数旧版本可能已经绑定原 OID，明确把公开查询重新接到扩展投影。
CREATE OR REPLACE FUNCTION meton_ledger.read_original_refund_aftercare(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT meton_ledger.refund_aftercare_view(ref,meton_ledger.original_refund_aftercare_context(route,ref))
$$;
REVOKE ALL ON FUNCTION meton_ledger.prepare_original_refund_aftercare(jsonb,uuid),meton_ledger.apply_original_refund_verification(jsonb,uuid,jsonb),
    meton_ledger.refund_aftercare_view(uuid,jsonb) FROM PUBLIC;
