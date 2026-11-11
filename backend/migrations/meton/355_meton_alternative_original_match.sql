/** 两库的同一原替代现金或双渠道关闭必须一致；只比较原结清记录，不复制金额分配或退款执行算法。 */
CREATE FUNCTION meton_ledger.alternative_original_matches(ref uuid,v jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE i meton_ledger.refund_alternative_intents; d meton_ledger.refund_alternative_decisions;
    r meton_ledger.cash_refunds; g meton_ledger.refund_gate_origins; payment uuid; c meton_ledger.refund_alternative_closures;
BEGIN
    IF v IS NULL OR v='null'::jsonb THEN RETURN false; END IF;
    SELECT * INTO i FROM meton_ledger.refund_alternative_intents WHERE refund=ref;
    SELECT * INTO d FROM meton_ledger.refund_alternative_decisions WHERE refund=ref;
    SELECT * INTO r FROM meton_ledger.cash_refunds WHERE refund_id=ref;
    SELECT * INTO g FROM meton_ledger.refund_gate_origins WHERE refund=ref;
    IF i.refund IS NULL OR d.choice IS DISTINCT FROM 'reserved' OR v->>'choice' IS DISTINCT FROM d.choice OR
        v->>'ticket' IS DISTINCT FROM d.ticket::text OR v->'proposal' IS DISTINCT FROM i.proposal OR
        i.proposal#>'{envelope,target}' IS DISTINCT FROM g.target OR g.refund IS NULL OR r.phase IS DISTINCT FROM v->>'phase' OR
        NOT EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries WHERE refund_id=ref AND phase=r.phase AND terminal_version=r.disposition_version) THEN RETURN false; END IF;
    IF r.part_id IS NOT NULL THEN SELECT payment_id INTO payment FROM meton_ledger.cash_parts WHERE part_id=r.part_id; END IF;
    IF meton_ledger.refund_payment_disputed(g.marker,r.native_order,payment,r.legacy_cutoff) THEN RETURN false; END IF;
    IF r.phase='settled' THEN
        RETURN EXISTS(SELECT FROM meton_ledger.refund_alternative_cash a JOIN meton_ledger.refund_cash_confirmations f USING(refund)
            JOIN meton_ledger.refund_cash_postings p USING(refund) WHERE a.refund=ref AND a.cash=v->'cash' AND
                encode(a.digest,'hex')=v->>'cashHash' AND a.digest=sha256(convert_to(a.cash::text,'UTF8')) AND
                (f.cash,f.economic_hash,f.envelope)=(a.cash,a.digest,i.proposal->'envelope') AND
                (p.marker,p.fen,p.units)=(g.marker,r.requested_fen,r.requested_units)) AND
            NOT EXISTS(SELECT FROM meton_ledger.refund_alternative_cash WHERE refund=ref AND cash IS DISTINCT FROM v->'cash') AND
            NOT EXISTS(SELECT FROM meton_ledger.refund_alternative_closures WHERE refund=ref);
    ELSIF r.phase='released' THEN
        SELECT * INTO c FROM meton_ledger.refund_alternative_closures WHERE refund=ref;
        RETURN c.refund IS NOT NULL AND c.terminal=v->'closure' AND
            EXISTS(SELECT FROM meton_ledger.cash_refund_recoveries WHERE refund_id=ref AND evidence=c.evidence) AND
            NOT EXISTS(SELECT FROM meton_ledger.refund_cash_confirmations WHERE refund=ref) AND
            NOT EXISTS(SELECT FROM meton_ledger.refund_cash_postings WHERE refund=ref) AND
            NOT EXISTS(SELECT FROM meton_ledger.refund_alternative_cash WHERE refund=ref);
    END IF;
    RETURN false;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.alternative_original_matches(uuid,jsonb) FROM PUBLIC;

-- 单独标明原现金匹配。旧来源只会缺少该标识，不能被新版 Meton 误当成替代退款已结清。
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_ledger.read_cash_archive_original(jsonb,jsonb)'::regprocedure);
    point text:='''financialAuthority'',false,''executionAuthorized'',false);';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'archive original result changed'; END IF;
    EXECUTE replace(body,point,'''financialAuthority'',false,''executionAuthorized'',false,
        ''cashMatch'',CASE WHEN state=''observed'' AND item#>>''{value,kind}''=''alternative'' AND
            meton_ledger.alternative_original_matches(g.refund,link->''alternativeTerminal'') THEN ''matched'' END);');
END $extend$;
