-- 已经可能出站的退款只接受原渠道确定关闭、唯一发送者永久退出及来源本身的验真观察。
CREATE FUNCTION meton_ledger.matches_closed_refund(owner jsonb,r meton_ledger.cash_refunds,terminal jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE o meton_ledger.cash_orders; p meton_ledger.cash_payments; n jsonb:=terminal->'notice'; basis jsonb;
BEGIN
    SELECT * INTO o FROM meton_ledger.cash_orders WHERE (native_order,source_marker)=(r.native_order,(owner->>'source_marker')::uuid);
    SELECT pay.* INTO p FROM meton_ledger.cash_parts b JOIN meton_ledger.cash_payments pay USING(payment_id)
        WHERE (b.part_id,b.source_marker,b.native_order,b.basis)=(r.part_id,o.source_marker,r.native_order,r.basis);
    IF o.native_order IS NULL OR p.payment_id IS NULL OR o.channel<>'wechatpay' OR
        (terminal->>'channel',terminal->>'cashEnvironment',terminal->>'merchant',terminal->>'app') IS DISTINCT FROM
            (o.channel,o.cash_environment,o.merchant_id,o.app_id) OR
        (n->>'kind',n->>'state',n->>'merchant',n->>'order',n->>'transaction',n->>'refundOrder',(n->>'refundFen')::bigint,
            (n->>'total')::bigint,(n->>'payerTotal')::bigint) IS DISTINCT FROM
            ('refund'::text,'CLOSED'::text,o.merchant_id,o.out_trade_no,p.channel_transaction,r.out_refund_no,r.requested_fen,p.order_fen,p.payer_fen) OR
        NOT coalesce(length(n->>'refundID') BETWEEN 1 AND 64,false) THEN RETURN false; END IF;
    basis:=meton_ledger.notification_origin(owner->>'environment',owner->>'source',(owner->>'epoch')::bigint,o.channel,o.cash_environment,o.merchant_id,o.app_id,n);
    IF ((basis->>'refund')::uuid,(basis->>'refundIntent')::uuid,(basis->>'part')::uuid,(basis->>'payment')::uuid,basis->>'basis') IS DISTINCT FROM
        (r.refund_id,r.intent_id,r.part_id,p.payment_id,r.basis) THEN RETURN false; END IF;
    RETURN EXISTS(SELECT FROM meton_ledger.cash_refund_observations s WHERE (s.native_order,s.source_marker,s.channel,s.cash_environment,s.merchant_id,s.transaction_id)=
        (o.native_order,o.source_marker,o.channel,o.cash_environment,o.merchant_id,p.channel_transaction) AND s.facts-'occurredAt'=n) AND
        NOT EXISTS(SELECT FROM meton_ledger.cash_refund_observations s WHERE (s.channel,s.cash_environment,s.merchant_id)=(o.channel,o.cash_environment,o.merchant_id)
            AND (s.facts->>'refundOrder'=r.out_refund_no OR s.facts->>'refundID'=n->>'refundID') AND
            (s.native_order,s.source_marker,s.transaction_id,s.facts-'occurredAt') IS DISTINCT FROM (o.native_order,o.source_marker,p.channel_transaction,n)) AND
        NOT EXISTS(SELECT FROM meton_ledger.cash_payment_conflicts c WHERE c.payment_id=p.payment_id OR
            (c.claimed_intent,c.claimed_marker)=(o.intent_id,o.source_marker));
END $$;

DO $failure$
DECLARE src text:=pg_get_functiondef('meton_ledger.apply_refund_gate_receipt(jsonb,uuid,uuid,jsonb)'::regprocedure);
    choices constant text:='choice NOT IN (''stopped'',''claimed'',''unsent'')';
    identity_at constant text:='proof_hash:=sha256(convert_to(jsonb_build_array(g.target,choice,f->>''ticket'')::text,''UTF8''));';
    phase_at constant text:='choice=''unsent'' AND r.phase IN';
    signal_at constant text:='OR EXISTS(SELECT FROM meton_ledger.cash_refund_observations signal WHERE';
BEGIN
    IF cardinality(string_to_array(src,choices))<>2 OR cardinality(string_to_array(src,identity_at))<>2 OR
        cardinality(string_to_array(src,phase_at))<>2 OR cardinality(string_to_array(src,signal_at))<>2 THEN RAISE EXCEPTION 'original refund release changed'; END IF;
    src:=replace(src,choices,'choice NOT IN (''stopped'',''claimed'',''unsent'',''failed'')');
    src:=replace(src,phase_at,'choice IN (''unsent'',''failed'') AND r.phase IN');
    src:=replace(src,signal_at,'OR choice<>''failed'' AND EXISTS(SELECT FROM meton_ledger.cash_refund_observations signal WHERE');
    EXECUTE replace(src,identity_at,identity_at||$proved$
    IF choice='failed' THEN
        IF NOT meton_ledger.matches_closed_refund(o,r,f->'terminal') THEN RETURN 'review'; END IF;
        proof_hash:=sha256(convert_to(jsonb_build_array(g.target,choice,f->>'ticket',f->'terminal')::text,'UTF8'));
    END IF;$proved$);
END $failure$;

CREATE FUNCTION meton_ledger.apply_verified_refund_failure(route jsonb,proof jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE facts jsonb:=proof->'facts'; t jsonb:=facts->'target'; ref uuid:=(t->>'refund')::uuid; m public.meton_managed_creations; owner jsonb;
BEGIN
    IF proof->>'state' IS DISTINCT FROM 'proved' OR facts->>'choice' IS DISTINCT FROM 'failed' OR
        (facts#>>'{scope,deployment}',facts#>>'{scope,source}',facts#>>'{scope,epoch}',facts#>>'{scope,sourceSystem}',facts#>>'{scope,inboxSystem}')
        IS DISTINCT FROM (route->>'deployment',route->>'source',route->>'epoch',route->>'sourceSystem',route->>'inboxSystem') OR
        (facts#>>'{terminal,channel}',facts#>>'{terminal,cashEnvironment}',facts#>>'{terminal,merchant}',facts#>>'{terminal,app}') IS DISTINCT FROM
        (route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN RAISE EXCEPTION 'wrong verified refund route' USING ERRCODE='42501'; END IF;
    SELECT c.* INTO m FROM public.meton_managed_creations c JOIN meton_ledger.cash_refund_decisions d ON c.source_marker=d.source_marker
        WHERE (d.refund_id,d.intent_id,c.source_marker,c.environment,c.source,c.epoch)=(ref,(t->>'intent')::uuid,(t->>'marker')::uuid,
            route->>'deployment',route->>'source',(route->>'epoch')::bigint);
    IF NOT FOUND THEN RETURN 'review'; END IF;
    owner:=jsonb_build_object('environment',m.environment,'source',m.source,'epoch',m.epoch,'user',m.meton_user,'account',m.account,'creation',m.operation,
        'dispatch',m.dispatch,'remote_user',m.remote_user,'source_marker',m.source_marker,'source_system',route->>'sourceSystem');
    RETURN meton_ledger.apply_refund_gate_receipt(owner,(t->>'intent')::uuid,ref,proof);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.matches_closed_refund(jsonb,meton_ledger.cash_refunds,jsonb),meton_ledger.apply_verified_refund_failure(jsonb,jsonb) FROM PUBLIC;
