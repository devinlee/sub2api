/** 放弃替代只停止替代路径；待办结束还须取得原渠道已保存的释放凭证，不能把选择本身当作退款终态。 */
CREATE FUNCTION meton_inbox.abandoned_original_terminal(ref uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_alternative_decisions; b meton_inbox.refund_wire_bindings;
    g meton_inbox.refund_gate_decisions; r meton_inbox.refund_sender_retirements;
    f meton_inbox.refund_failed_proofs; cash_identity bytea; release_facts jsonb; closed jsonb;
BEGIN
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice='abandoned';
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    SELECT * INTO g FROM meton_inbox.refund_gate_decisions WHERE refund=ref;
    IF d.refund IS NULL OR b.refund IS NULL OR g.refund IS NULL OR d.proposal->'envelope' IS DISTINCT FROM b.envelope OR
        g.target IS DISTINCT FROM b.envelope->'target' THEN RETURN NULL; END IF;
    cash_identity:=meton_inbox.cash_original_identity(b.envelope);
    IF EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.alternative_cash_positive WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.alternative_cash_closures WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.refund_positive_cash WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.refund_cash_disputes WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant)=(b.channel,b.cash_environment,b.merchant)) OR
        EXISTS(SELECT FROM meton_inbox.refund_evidence e WHERE e.original=cash_identity AND NOT EXISTS(
            SELECT FROM meton_inbox.refund_terminal_facts t WHERE (t.receipt,t.digest)=(e.receipt,e.digest))) OR
        EXISTS(SELECT FROM meton_inbox.refund_resolution_samples(b) s WHERE
            NOT s.correct_owner OR s.conflicted OR s.reported IN ('SUCCESS','ABNORMAL')) THEN RETURN NULL; END IF;
    IF g.choice='stopped' THEN
        release_facts:=jsonb_build_object('target',g.target,'choice','stopped','ticket',g.ticket);
    ELSIF g.choice='claimed' THEN
        SELECT * INTO r FROM meton_inbox.refund_sender_retirements WHERE (refund,ticket)=(ref,g.ticket);
        IF r.refund IS NULL THEN RETURN NULL; END IF;
        IF NOT r.may_have_sent THEN
            release_facts:=jsonb_build_object('target',g.target,'choice','unsent','ticket',g.ticket);
        ELSE
            SELECT * INTO f FROM meton_inbox.refund_failed_proofs WHERE (refund,ticket)=(ref,g.ticket);
            IF f.refund IS NULL OR f.terminal#>>'{notice,state}' IS DISTINCT FROM 'CLOSED' THEN RETURN NULL; END IF;
            SELECT jsonb_build_object('order',n->'order','transaction',n->'transaction','refundOrder',n->'refundOrder',
                'refundID',n->'refundID','total',n->'total','payerTotal',n->'payerTotal','refundFen',n->'refundFen','payerRefund',n->'payerRefund')
                INTO closed FROM (SELECT f.terminal->'notice' AS n) original;
            IF NOT EXISTS(SELECT FROM meton_inbox.refund_resolution_samples(b) s WHERE
                s.transport IN ('GET','callback') AND s.reported='CLOSED' AND s.fields=closed) OR
                EXISTS(SELECT FROM meton_inbox.refund_resolution_samples(b) s WHERE s.fields IS DISTINCT FROM closed) THEN RETURN NULL; END IF;
            release_facts:=jsonb_build_object('target',g.target,'choice','failed','ticket',g.ticket,'terminal',f.terminal);
        END IF;
    ELSE RETURN NULL;
    END IF;
    RETURN jsonb_build_object('proposal',d.proposal,'choice',d.choice,'ticket',d.ticket,'phase','released','originalRelease',release_facts);
END $$;
REVOKE ALL ON FUNCTION meton_inbox.abandoned_original_terminal(uuid) FROM PUBLIC;

-- 保留原 reserved 算法；新增分支只读取 abandoned 的原不可变记录，不执行停止、释放或新的派发。
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_inbox.alternative_original_terminal(uuid)'::regprocedure);
    point text:='SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice=''reserved'';';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative terminal reader changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice=''abandoned'') THEN
        RETURN meton_inbox.abandoned_original_terminal(ref); END IF; '||point);
END $extend$;
