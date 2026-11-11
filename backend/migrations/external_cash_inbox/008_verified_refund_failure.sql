-- 已验签的同一收件保存最小判定字段。原回调正文和验签密钥继续沿既有加密证明保存。
CREATE TABLE meton_inbox.refund_terminal_facts(
    receipt uuid NOT NULL,digest bytea NOT NULL,original bytea NOT NULL,canonical bytea NOT NULL,
    channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,app text NOT NULL,
    outcome jsonb NOT NULL,origin jsonb NOT NULL,seen_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),PRIMARY KEY(receipt,digest),
    FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.refund_evidence(receipt,digest)
);
CREATE INDEX refund_terminal_number ON meton_inbox.refund_terminal_facts(channel,cash_environment,merchant,(outcome->>'refundOrder'));
CREATE TABLE meton_inbox.refund_failed_proofs(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_gate_decisions,ticket uuid NOT NULL,
    terminal jsonb NOT NULL,receipt uuid NOT NULL,digest bytea NOT NULL,recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    FOREIGN KEY(refund,ticket) REFERENCES meton_inbox.refund_gate_decisions(refund,ticket),
    FOREIGN KEY(receipt,digest) REFERENCES meton_inbox.refund_terminal_facts(receipt,digest)
);
CREATE TRIGGER immutable_terminal BEFORE UPDATE OR DELETE ON meton_inbox.refund_terminal_facts FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
CREATE TRIGGER immutable_failure BEFORE UPDATE OR DELETE ON meton_inbox.refund_failed_proofs FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.refund_terminal_facts ENABLE ALWAYS TRIGGER immutable_terminal;
ALTER TABLE meton_inbox.refund_failed_proofs ENABLE ALWAYS TRIGGER immutable_failure;
REVOKE ALL ON meton_inbox.refund_terminal_facts,meton_inbox.refund_failed_proofs FROM PUBLIC;

CREATE FUNCTION meton_inbox.capture_refund_terminal(route jsonb,ref_id uuid,proof_digest bytea,lease_id uuid,canonical_wire bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE wire jsonb; n jsonb; o jsonb; identity bytea; canonical_hash bytea;
BEGIN
    PERFORM FROM meton_inbox.read_refund_notice(route,ref_id,proof_digest,lease_id);
    IF NOT FOUND OR canonical_wire IS NULL OR octet_length(canonical_wire)>32768 THEN RAISE EXCEPTION 'missing verified refund lease' USING ERRCODE='42501'; END IF;
    wire:=convert_from(canonical_wire,'UTF8')::jsonb;n:=wire->'notice';o:=wire->'origin';canonical_hash:=sha256(canonical_wire);
    -- 收件摘要属于原验签报文。即使持有消费权限，也不能把 ABNORMAL 或 SUCCESS 换成 CLOSED。
    identity:=meton_inbox.lock_original_cash(route,n->>'order',n->>'transaction');
    IF NOT EXISTS(SELECT FROM meton_inbox.refund_evidence i WHERE (i.receipt,i.digest,i.original,i.canonical)=(ref_id,proof_digest,identity,canonical_hash)) OR
        (n->>'kind'='refund' AND n->>'state' IN ('CLOSED','SUCCESS','ABNORMAL') AND n->>'merchant'=route->>'merchant' AND n->>'order'=o->>'order'
        AND (o->>'channel',o->>'cashEnvironment',o->>'merchant',o->>'app')=(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app')
        AND length(n->>'refundID') BETWEEN 1 AND 64 AND length(n->>'refundOrder') BETWEEN 1 AND 64
        AND (n->>'refundFen')::bigint BETWEEN 1 AND (n->>'total')::bigint AND (n->>'payerRefund')::bigint BETWEEN 0 AND (n->>'refundFen')::bigint) IS NOT TRUE THEN
        RAISE EXCEPTION 'refund evidence differs from signed original' USING ERRCODE='42501'; END IF;
    INSERT INTO meton_inbox.refund_terminal_facts(receipt,digest,original,canonical,channel,cash_environment,merchant,app,outcome,origin)
        VALUES(ref_id,proof_digest,identity,canonical_hash,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',n-'delivery',o)
        ON CONFLICT DO NOTHING;
    IF NOT EXISTS(SELECT FROM meton_inbox.refund_terminal_facts t WHERE (t.receipt,t.digest,t.original,t.canonical,t.outcome,t.origin)=
        (ref_id,proof_digest,identity,canonical_hash,n-'delivery',o)) THEN RAISE EXCEPTION 'original refund evidence conflict' USING ERRCODE='23505'; END IF;
END $$;

-- 返回 retry 要求在新的事务中查已提交原事实。review 保留已收的异常／矛盾材料，不交付任何释放证明。
CREATE FUNCTION meton_inbox.original_refund_failure(route jsonb,ref_id uuid,proof_digest bytea,lease_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t meton_inbox.refund_terminal_facts; d meton_inbox.refund_gate_decisions; a meton_inbox.refund_gate_authorities;
    retirement meton_inbox.refund_sender_retirements; sealed meton_inbox.refund_failed_proofs; n jsonb; terminal jsonb; facts jsonb; scope jsonb; ref uuid;
BEGIN
    PERFORM FROM meton_inbox.read_refund_notice(route,ref_id,proof_digest,lease_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'original refund proof lease differs' USING ERRCODE='42501'; END IF;
    SELECT * INTO t FROM meton_inbox.refund_terminal_facts WHERE (receipt,digest)=(ref_id,proof_digest);
    IF NOT FOUND OR t.seen_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','retry'); END IF;
    n:=t.outcome;
    IF n->>'state'<>'CLOSED' OR n->>'refundOrder' !~ '^R[0-9a-f]{32}$' THEN RETURN jsonb_build_object('state','review'); END IF;
    PERFORM meton_inbox.lock_original_cash(route,n->>'order',n->>'transaction');
    ref:=substring(n->>'refundOrder' FROM 2)::uuid;
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.refund.transport.v1/'||ref::text,0));
    SELECT * INTO d FROM meton_inbox.refund_gate_decisions WHERE refund=ref;
    SELECT * INTO a FROM meton_inbox.refund_gate_authorities WHERE (deployment,source,epoch,source_system)=
        (route->>'deployment',route->>'source',(route->>'epoch')::bigint,route->>'sourceSystem') AND source_system<>meton_inbox.system_id()
        AND route->>'inboxSystem'=meton_inbox.system_id() FOR SHARE;
    IF NOT FOUND OR d.refund IS NULL OR d.choice<>'claimed' OR d.sender_hash IS NULL OR a.sender=session_user OR a.stopper=session_user OR
        (t.channel,t.cash_environment,t.merchant,t.app) IS DISTINCT FROM (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') OR
        route->>'channel'<>'wechatpay' OR (d.target->>'marker',d.target->>'outRefundNo',(d.target->>'fen')::bigint)
        IS DISTINCT FROM (t.origin->>'sourceMarker',n->>'refundOrder',(n->>'refundFen')::bigint) THEN RETURN jsonb_build_object('state','review'); END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'sourceSystem',a.source_system,
        'inboxSystem',meton_inbox.system_id(),'keyRef',a.key_ref);
    IF scope IS DISTINCT FROM d.issued_scope-'validUntil' THEN RETURN jsonb_build_object('state','review'); END IF;
    SELECT * INTO retirement FROM meton_inbox.refund_sender_retirements WHERE (refund,ticket)=(ref,d.ticket);
    IF NOT FOUND OR retirement.retired_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','retry'); END IF;
    IF NOT retirement.may_have_sent THEN RETURN jsonb_build_object('state','review'); END IF;
    -- 先到、后到及旧格式尚未分类的材料都可能涉及这笔退款。只要不能排除冲突就不释放。
    IF EXISTS(SELECT FROM meton_inbox.unindexed_refunds u WHERE (u.channel,u.cash_environment,u.merchant)=(t.channel,t.cash_environment,t.merchant)) OR
        EXISTS(SELECT FROM meton_inbox.refund_evidence i JOIN meton_inbox.receipts r USING(receipt)
            LEFT JOIN meton_inbox.refund_terminal_facts known ON (known.receipt,known.digest)=(i.receipt,i.digest)
            WHERE (r.channel,r.cash_environment,r.merchant)=(t.channel,t.cash_environment,t.merchant) AND known.receipt IS NULL) THEN
        RETURN jsonb_build_object('state','retry'); END IF;
    IF EXISTS(SELECT FROM meton_inbox.refund_terminal_facts x WHERE (x.channel,x.cash_environment,x.merchant,x.outcome->>'refundOrder')=
        (t.channel,t.cash_environment,t.merchant,n->>'refundOrder') AND (x.original<>t.original OR x.app<>t.app OR x.origin<>t.origin OR
            x.outcome-'occurredAt'<>n-'occurredAt')) OR
        EXISTS(SELECT FROM meton_inbox.proofs p JOIN meton_inbox.refund_terminal_facts f USING(receipt)
        WHERE f.original=t.original AND f.outcome->>'refundOrder'=n->>'refundOrder' AND NOT p.first_proof) THEN
        RETURN jsonb_build_object('state','review'); END IF;
    terminal:=jsonb_build_object('channel',t.channel,'cashEnvironment',t.cash_environment,'merchant',t.merchant,'app',t.app,'notice',n-'occurredAt');
    INSERT INTO meton_inbox.refund_failed_proofs(refund,ticket,terminal,receipt,digest)
        VALUES(ref,d.ticket,terminal,t.receipt,t.digest) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT sealed FROM meton_inbox.refund_failed_proofs WHERE refund=ref;
    IF sealed.ticket<>d.ticket OR sealed.terminal<>terminal THEN RETURN jsonb_build_object('state','review'); END IF;
    IF sealed.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','retry'); END IF;
    facts:=jsonb_build_object('format',1,'scope',scope,'target',d.target,'choice','failed','ticket',d.ticket,'terminal',sealed.terminal,
        'receipt',sealed.receipt,'proofHash',encode(sealed.digest,'hex'));
    RETURN jsonb_build_object('state','proved','facts',facts,'mac',encode(meton_inbox.refund_seal_mac(convert_to(facts::text,'UTF8'),a.seal_key),'hex'));
END $$;
REVOKE ALL ON FUNCTION meton_inbox.capture_refund_terminal(jsonb,uuid,bytea,uuid,bytea),
    meton_inbox.original_refund_failure(jsonb,uuid,bytea,uuid) FROM PUBLIC;
