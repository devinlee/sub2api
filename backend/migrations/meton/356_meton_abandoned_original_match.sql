/** 只比较原释放的不可变凭证。替代已放弃既不返还额度，也不替代来源的原占用释放事务。 */
CREATE FUNCTION meton_ledger.abandoned_original_matches(ref uuid,v jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE i meton_ledger.refund_alternative_intents; d meton_ledger.refund_alternative_decisions;
    r meton_ledger.cash_refunds; g meton_ledger.refund_gate_origins;
    release_facts jsonb:=v->'originalRelease'; proof_hash bytea; payment uuid;
BEGIN
    SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    SELECT * INTO r FROM meton_ledger.cash_refunds WHERE refund_id=ref;
    SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE refund=ref;
    IF i.refund IS NULL OR d.choice IS DISTINCT FROM 'abandoned' OR g.refund IS NULL OR
        v->>'choice' IS DISTINCT FROM d.choice OR v->>'ticket' IS DISTINCT FROM d.ticket::text OR
        v->'proposal' IS DISTINCT FROM i.proposal OR i.digest<>sha256(convert_to(i.proposal::text,'UTF8')) OR d.digest<>i.digest OR
        i.proposal#>'{envelope,target}' IS DISTINCT FROM g.target OR release_facts->'target' IS DISTINCT FROM g.target OR
        v->>'phase' IS DISTINCT FROM 'released' OR r.phase IS DISTINCT FROM 'released' OR
        (release_facts->>'choice' IN ('stopped','unsent','failed') AND (release_facts->>'ticket')::uuid IS NOT NULL) IS NOT TRUE THEN RETURN false; END IF;
    IF r.part_id IS NOT NULL THEN SELECT payment_id INTO payment FROM meton_ledger.cash_parts WHERE part_id=r.part_id; END IF;
    IF meton_ledger.refund_payment_disputed(g.marker,r.native_order,payment,r.legacy_cutoff) OR
        EXISTS(SELECT FROM meton_ledger.refund_cash_confirmations WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_ledger.refund_cash_postings WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_ledger.refund_alternative_cash WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_ledger.refund_alternative_closures WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_ledger.cash_refund_observations o WHERE
            (o.source_marker,o.native_order,o.facts->>'refundOrder')=(g.marker,r.native_order,r.out_refund_no) AND
            NOT meton_ledger.refund_observation_resolved(o)) THEN RETURN false; END IF;
    proof_hash:=sha256(convert_to(jsonb_build_array(g.target,release_facts->>'choice',release_facts->>'ticket')::text,'UTF8'));
    IF release_facts->>'choice'='failed' THEN
        proof_hash:=sha256(convert_to(jsonb_build_array(g.target,'failed',release_facts->>'ticket',release_facts->'terminal')::text,'UTF8'));
        IF NOT EXISTS(SELECT FROM meton_ledger.refund_closed_returns c WHERE c.refund=ref AND
            c.ticket::text=release_facts->>'ticket' AND c.terminal=release_facts->'terminal' AND c.evidence=proof_hash) THEN RETURN false; END IF;
    ELSIF EXISTS(SELECT FROM meton_ledger.refund_closed_returns WHERE refund=ref) THEN RETURN false;
    END IF;
    RETURN EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries h WHERE
        (h.refund_id,h.phase,h.terminal_version,h.confirmed_fen,h.confirmed_units,h.evidence)=
        (ref,'released',r.disposition_version,0,0,proof_hash));
END $$;
REVOKE ALL ON FUNCTION meton_ledger.abandoned_original_matches(uuid,jsonb) FROM PUBLIC;

DO $extend$
DECLARE body text:=pg_get_functiondef('meton_ledger.alternative_original_matches(uuid,jsonb)'::regprocedure);
    point text:='IF v IS NULL OR v=''null''::jsonb THEN RETURN false; END IF;';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative original comparison changed'; END IF;
    EXECUTE replace(body,point,point||' IF v->>''choice''=''abandoned'' THEN RETURN meton_ledger.abandoned_original_matches(ref,v); END IF;');
END $extend$;
