/** 只比较既有原现金凭证，不领取、发送或补造终态。未索引通知及新矛盾必须保留待核对。 */
CREATE FUNCTION meton_inbox.alternative_original_terminal(ref uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE d meton_inbox.refund_alternative_decisions; b meton_inbox.refund_wire_bindings;
    p meton_inbox.alternative_cash_positive; c meton_inbox.alternative_cash_closures;
    closed jsonb; cash_identity bytea; n bigint;
BEGIN
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice='reserved';
    SELECT * INTO b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    IF d.refund IS NULL OR b.refund IS NULL OR d.proposal->'envelope' IS DISTINCT FROM b.envelope THEN RETURN NULL; END IF;
    cash_identity:=meton_inbox.cash_original_identity(b.envelope);
    IF EXISTS(SELECT FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant)=(b.channel,b.cash_environment,b.merchant)) OR
        EXISTS(SELECT FROM meton_inbox.refund_evidence e WHERE e.original=cash_identity AND NOT EXISTS(
            SELECT FROM meton_inbox.refund_terminal_facts f WHERE (f.receipt,f.digest)=(e.receipt,e.digest))) OR
        EXISTS(SELECT FROM meton_inbox.refund_positive_cash WHERE refund=ref) OR
        EXISTS(SELECT FROM meton_inbox.refund_cash_disputes WHERE refund=ref) THEN RETURN NULL; END IF;
    SELECT s.fields INTO closed FROM meton_inbox.refund_resolution_samples(b) s
        WHERE s.transport IN ('GET','callback') AND s.reported='CLOSED' AND s.correct_owner AND NOT s.conflicted ORDER BY s.fields::text LIMIT 1;
    IF closed IS NULL OR EXISTS(SELECT FROM meton_inbox.refund_resolution_samples(b) s WHERE
        NOT s.correct_owner OR s.conflicted OR s.reported IN ('SUCCESS','ABNORMAL') OR s.fields IS DISTINCT FROM closed) THEN RETURN NULL; END IF;
    SELECT count(*) INTO n FROM meton_inbox.alternative_cash_positive WHERE refund=ref;
    IF n=1 THEN
        SELECT * INTO STRICT p FROM meton_inbox.alternative_cash_positive WHERE refund=ref;
        IF p.cash->'payment' IS DISTINCT FROM d.proposal->'payment' OR p.economic_hash<>sha256(convert_to(p.cash::text,'UTF8')) OR
            EXISTS(SELECT FROM meton_inbox.alternative_cash_closures WHERE refund=ref) OR
            EXISTS(SELECT FROM meton_inbox.alternative_cash_observations o WHERE o.refund=ref AND
                (o.facts->>'state' IN ('failed','closed') OR o.facts->>'state'='succeeded' AND
                    jsonb_build_object('payment',o.facts->'payment','transaction',o.facts->'transaction') IS DISTINCT FROM p.cash)) OR
            EXISTS(SELECT FROM meton_inbox.alternative_cash_observations o WHERE o.refund<>ref AND o.facts->>'state'='succeeded' AND
                (o.facts#>>'{payment,rail}',o.facts#>>'{payment,environment}',o.facts#>>'{payment,merchant}',o.facts->>'transaction')=
                (p.cash#>>'{payment,rail}',p.cash#>>'{payment,environment}',p.cash#>>'{payment,merchant}',p.cash->>'transaction')) THEN RETURN NULL; END IF;
        RETURN jsonb_build_object('proposal',d.proposal,'choice',d.choice,'ticket',d.ticket,'phase','settled',
            'cash',p.cash,'cashHash',encode(p.economic_hash,'hex'));
    ELSIF n=0 THEN
        SELECT * INTO c FROM meton_inbox.alternative_cash_closures WHERE refund=ref;
        IF c.refund IS NULL OR c.terminal->'originalClosed' IS DISTINCT FROM closed OR
            c.terminal->>'ticket' IS DISTINCT FROM d.ticket::text OR
            NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_stops WHERE refund=ref AND reason=c.terminal->>'stopReason') OR
            EXISTS(SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref AND facts->>'state'='succeeded') OR
            (c.terminal->>'reason'='unsent' AND EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=ref)) OR
            (c.terminal->>'reason'='channel_closed' AND NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_observations
                WHERE refund=ref AND verb='GET' AND facts->>'state'='closed')) OR
            (c.terminal->>'reason' IN ('unsent','channel_closed')) IS NOT TRUE THEN RETURN NULL; END IF;
        RETURN jsonb_build_object('proposal',d.proposal,'choice',d.choice,'ticket',d.ticket,'phase','released','closure',c.terminal);
    END IF;
    RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION meton_inbox.alternative_original_terminal(uuid) FROM PUBLIC;

-- 终态材料只在现有用途签章内部传递，不增加公开列表字段或读者权限。
DO $extend$
DECLARE body text:=pg_get_functiondef('meton_inbox.read_cash_archive_link(jsonb,text)'::regprocedure);
    point text:='jsonb_build_object(''kind'',''refund'',''target'',d.proposal#>''{envelope,target}'')';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative archive link changed'; END IF;
    EXECUTE replace(body,point,'jsonb_build_object(''kind'',''refund'',''target'',d.proposal#>''{envelope,target}'',
        ''alternativeTerminal'',meton_inbox.alternative_original_terminal(ref))');
END $extend$;
