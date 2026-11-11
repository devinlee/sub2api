-- 原渠道交易与原商品各有唯一身份。独立收件编号、签名版本和查询次数均不进入这两个键。
CREATE TABLE meton_ledger.cash_order_awards (
    native_order bigint PRIMARY KEY, source_marker uuid NOT NULL, payment_id uuid NOT NULL UNIQUE,
    part_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    FOREIGN KEY(payment_id,native_order,source_marker) REFERENCES meton_ledger.cash_payments(payment_id,native_order,source_marker)
);
CREATE TABLE meton_ledger.cash_payment_conflicts (
    payment_id uuid NOT NULL REFERENCES meton_ledger.cash_payments, digest bytea NOT NULL CHECK(octet_length(digest)=32),
    claimed_intent uuid NOT NULL, claimed_marker uuid NOT NULL, claimed_transaction jsonb NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(payment_id,digest)
);
DO $$ DECLARE item text; BEGIN
    FOREACH item IN ARRAY ARRAY['cash_order_awards','cash_payment_conflicts'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_original BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',item);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_original',item);
    END LOOP;
END $$;
REVOKE ALL ON meton_ledger.cash_order_awards,meton_ledger.cash_payment_conflicts FROM PUBLIC;

-- S1 证明“从未有资金”必须继续把任何原生订单视为活动。开首笔来源时，同账号由受控报价生成的
-- 订单已经存在，可以从旧活动检查中剔除这一个已知来源。沿用其余出生、余额、历史和触发器检查。
DO $opening$
DECLARE history text:=pg_get_functiondef('public.meton_s1_funds_state(text,text,bigint,uuid)'::regprocedure);
    posting text:=pg_get_functiondef('meton_ledger.credit_origin(text,text,bigint,uuid,uuid,uuid,uuid,text,uuid,text,text,text,text,text,text)'::regprocedure);
    history_name constant text:='FUNCTION public.meton_s1_funds_state(';
    orders constant text:='EXISTS(SELECT FROM public.payment_orders o WHERE o.user_id=u.id)';
    convert_guard constant text:='OR face*rate<>amount THEN';
    opening_guard constant text:='FROM public.meton_s1_funds_state(p_env,p_source,p_epoch,creation.operation)';
BEGIN
    IF cardinality(string_to_array(history,history_name))<>2 OR cardinality(string_to_array(history,orders))<>2
        OR cardinality(string_to_array(posting,convert_guard))<>2 OR cardinality(string_to_array(posting,opening_guard))<>2 THEN
        RAISE EXCEPTION 'original credit checks changed'; END IF;
    EXECUTE replace(replace(history,history_name,'FUNCTION meton_ledger.cash_opening_state('),orders,$owned$
        EXISTS(SELECT FROM public.payment_orders o WHERE o.user_id=u.id AND NOT EXISTS (
            SELECT FROM meton_ledger.cash_orders known JOIN meton_ledger.cash_order_attempts a
                USING(native_order,intent_id,source_marker)
            WHERE (known.native_order,known.remote_user,known.out_trade_no,known.source_marker)=(o.id,u.id,o.out_trade_no,m.source_marker)
            AND o.order_type='meton_purchase'))
        $owned$);
    -- 仍由 S2 原核完成事件、来源、原生余额和 outbox 的唯一提交。只对原报价已明确舍入的购买开放八位换算。
    EXECUTE replace(replace(posting,opening_guard,'FROM meton_ledger.cash_opening_state(p_env,p_source,p_epoch,creation.operation)'),
        convert_guard,$priced$ OR (face*rate<>amount AND NOT (p_kind='purchase' AND p_operation=p_origin AND EXISTS (
            SELECT FROM meton_ledger.cash_order_awards a JOIN meton_ledger.cash_orders o USING(native_order,source_marker)
            WHERE a.part_id=p_origin AND a.source_marker=p_marker AND o.unit=p_unit AND o.price_version=p_rule
              AND o.currency=p_denomination AND o.price_fen::numeric/100=face AND o.units_per_yuan=rate
              AND o.credit_units=amount AND round(face*rate,8)=amount))) THEN$priced$);
END $opening$;
REVOKE ALL ON FUNCTION meton_ledger.cash_opening_state(text,text,bigint,uuid) FROM PUBLIC;

CREATE FUNCTION meton_ledger.require_cash_writer(deployment text, source_name text, generation bigint) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR current_setting('transaction_read_only')<>'off'
        OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'cash writes unavailable' USING ERRCODE='55000'; END IF;
    PERFORM FROM public.meton_managed_fence WHERE singleton AND enabled
        AND (environment,source,epoch)=(deployment,source_name,generation) FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'cash writer retired' USING ERRCODE='55000'; END IF;
END $$;

-- 通知和主动查询都交回已核实的原单证明和渠道字段。来源本身再次复验；用户、会话和到账量均不能由来访者选择。
CREATE FUNCTION meton_ledger.observe_cash_payment(deployment text,source_name text,generation bigint,origin jsonb,facts jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    o meton_ledger.cash_orders%ROWTYPE; p meton_ledger.cash_payments%ROWTYPE; d meton_ledger.cash_payment_dispositions%ROWTYPE;
    actual jsonb; claim jsonb; paid timestamptz; total bigint; payer bigint; first_payment boolean;
BEGIN
    PERFORM meton_ledger.require_cash_writer(deployment,source_name,generation);
    IF facts->>'kind' IS DISTINCT FROM 'payment' OR facts->>'state' IS DISTINCT FROM 'SUCCESS' OR
        coalesce(length(facts->>'transaction') BETWEEN 1 AND 64,false) IS NOT TRUE OR facts->>'occurredAt' IS NULL THEN
        RAISE EXCEPTION 'verified payment required' USING ERRCODE='22023'; END IF;
    paid:=(facts->>'occurredAt')::timestamptz; total:=(facts->>'total')::bigint; payer:=(facts->>'payerTotal')::bigint;
    IF NOT isfinite(paid) OR total IS NULL OR payer IS NULL OR total<=0 OR payer NOT BETWEEN 0 AND total THEN
        RAISE EXCEPTION 'invalid channel amount' USING ERRCODE='22023'; END IF;
    SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE intent_id=(origin->>'intent')::uuid FOR UPDATE;
    actual:=meton_ledger.notification_origin(deployment,source_name,generation,o.channel,o.cash_environment,o.merchant_id,o.app_id,facts);
    IF actual IS DISTINCT FROM origin THEN RAISE EXCEPTION 'original payment owner differs' USING ERRCODE='42501'; END IF;
    -- 同一原订单串行选择商品归属。跨订单争用同一渠道交易时另按稳定现金身份串行，唯一约束仍是最终裁决。
    PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(o.channel,o.cash_environment,o.merchant_id,facts->>'transaction')::text,0));
    SELECT * INTO p FROM meton_ledger.cash_payments WHERE (channel,cash_environment,merchant_id,channel_transaction)=
        (o.channel,o.cash_environment,o.merchant_id,facts->>'transaction');
    IF FOUND THEN
        IF (p.native_order,p.source_marker,p.order_fen,p.payer_fen,p.currency,p.payer_currency,p.paid_at)
            IS DISTINCT FROM (o.native_order,o.source_marker,total,payer,facts->>'currency',facts->>'payerCurrency',paid) THEN
            claim:=jsonb_build_array(o.intent_id,o.source_marker,total,payer,facts->>'currency',facts->>'payerCurrency',
                extract(epoch FROM paid),facts->>'transaction');
            INSERT INTO meton_ledger.cash_payment_conflicts(payment_id,digest,claimed_intent,claimed_marker,claimed_transaction)
                VALUES(p.payment_id,sha256(convert_to(claim::text,'UTF8')),o.intent_id,o.source_marker,claim) ON CONFLICT DO NOTHING;
            UPDATE meton_ledger.cash_payment_dispositions SET version=version+1,state='restricted'
                WHERE payment_id=p.payment_id AND state IN ('received','ready');
            RETURN jsonb_build_object('state','conflict');
        END IF;
    ELSE
        first_payment:=NOT EXISTS(SELECT FROM meton_ledger.cash_payments WHERE native_order=o.native_order);
        INSERT INTO meton_ledger.cash_payments(payment_id,native_order,source_marker,channel,cash_environment,merchant_id,channel_transaction,
            order_fen,payer_fen,currency,payer_currency,paid_at)
            VALUES(gen_random_uuid(),o.native_order,o.source_marker,o.channel,o.cash_environment,o.merchant_id,facts->>'transaction',
                total,payer,o.currency,o.currency,paid) RETURNING * INTO p;
        INSERT INTO meton_ledger.cash_payment_dispositions VALUES(p.payment_id,1,'received');
        IF first_payment AND paid BETWEEN o.created_at AND o.expires_at AND payer>0 THEN
            INSERT INTO meton_ledger.cash_order_awards(native_order,source_marker,payment_id) VALUES(o.native_order,o.source_marker,p.payment_id);
        ELSE
            UPDATE meton_ledger.cash_payment_dispositions SET version=version+1,state='restricted' WHERE payment_id=p.payment_id;
            IF payer>0 THEN
                INSERT INTO meton_ledger.cash_parts(part_id,payment_id,native_order,source_marker,basis,basis_fen)
                    VALUES(gen_random_uuid(),p.payment_id,o.native_order,o.source_marker,'unposted_cash',payer);
            END IF;
        END IF;
    END IF;
    SELECT * INTO STRICT d FROM meton_ledger.cash_payment_dispositions WHERE payment_id=p.payment_id;
    RETURN jsonb_build_object('payment',p.payment_id,'state',d.state,'version',d.version);
END $$;

-- 工作者先持久记录现金，可独立显示已付待入账。取得旧处置版本的工作不能绕过退款占用、终止或冲突。
CREATE FUNCTION meton_ledger.fulfil_cash_payment(deployment text,source_name text,generation bigint,marker uuid,
    original_intent uuid,payment uuid,expected_version bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE
    o meton_ledger.cash_orders%ROWTYPE; p meton_ledger.cash_payments%ROWTYPE; d meton_ledger.cash_payment_dispositions%ROWTYPE;
    a meton_ledger.cash_order_awards%ROWTYPE; m public.meton_managed_creations%ROWTYPE; effect meton_ledger.events%ROWTYPE;
BEGIN
    PERFORM meton_ledger.require_cash_writer(deployment,source_name,generation);
    SELECT * INTO STRICT o FROM meton_ledger.cash_orders WHERE (intent_id,source_marker)=(original_intent,marker) FOR UPDATE;
    SELECT * INTO STRICT p FROM meton_ledger.cash_payments WHERE (payment_id,native_order,source_marker)=(payment,o.native_order,marker);
    SELECT * INTO STRICT m FROM public.meton_managed_creations WHERE (source_marker,remote_user,environment,source,epoch)=
        (marker,o.remote_user,deployment,source_name,generation) FOR SHARE;
    SELECT * INTO STRICT d FROM meton_ledger.cash_payment_dispositions WHERE payment_id=payment FOR UPDATE;
    SELECT e.* INTO effect FROM meton_ledger.cash_parts part JOIN meton_ledger.events e ON e.event_id=part.credit_event
        WHERE part.payment_id=payment AND part.native_order=o.native_order AND part.source_marker=marker AND part.basis='purchased_source';
    IF FOUND THEN
        RETURN jsonb_build_object('state','posted','payment',payment,'event',effect.event_id,'sequence',effect.sequence);
    END IF;
    SELECT * INTO a FROM meton_ledger.cash_order_awards WHERE native_order=o.native_order AND source_marker=marker AND payment_id=payment;
    IF NOT FOUND OR d.state NOT IN ('received','ready') OR d.version IS DISTINCT FROM expected_version
        OR EXISTS(SELECT FROM meton_ledger.cash_payment_conflicts WHERE payment_id=payment)
        OR EXISTS(SELECT FROM meton_ledger.cash_parts WHERE payment_id=payment AND basis='unposted_cash')
        OR EXISTS(SELECT FROM meton_ledger.gift_terminations WHERE source_marker=marker) THEN
        RETURN jsonb_build_object('state','restricted','payment',payment,'version',d.version);
    END IF;
    PERFORM FROM public.users WHERE id=m.remote_user AND status='active' AND role='user' AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('state','restricted','payment',payment,'version',d.version); END IF;
    SELECT * INTO STRICT effect FROM meton_ledger.credit_origin(deployment,source_name,generation,m.meton_user,m.account,marker,
        a.part_id,'purchase',a.part_id,o.unit,o.price_version,o.currency,(o.price_fen::numeric/100)::numeric(20,8)::text,
        o.units_per_yuan::text,o.credit_units::text);
    INSERT INTO meton_ledger.cash_parts(part_id,payment_id,native_order,source_marker,basis,basis_fen,credit_event)
        VALUES(a.part_id,payment,o.native_order,marker,'purchased_source',p.payer_fen,effect.event_id);
    UPDATE meton_ledger.cash_payment_dispositions SET state='resolved',version=version+1 WHERE payment_id=payment;
    RETURN jsonb_build_object('state','posted','payment',payment,'event',effect.event_id,'sequence',effect.sequence);
END $$;
REVOKE ALL ON FUNCTION meton_ledger.require_cash_writer(text,text,bigint),
    meton_ledger.observe_cash_payment(text,text,bigint,jsonb,jsonb),
    meton_ledger.fulfil_cash_payment(text,text,bigint,uuid,uuid,uuid,bigint) FROM PUBLIC;

-- 原生状态随原账本事务呈现。只允许由对应的原现金记录或购买来源触发，直接写表仍受 298 的旧门禁约束。
DO $native_guard$
DECLARE src text:=pg_get_functiondef('meton_ledger.guard_native_purchase()'::regprocedure);
    marker constant text:='IF TG_OP<>''INSERT'' AND EXISTS(SELECT FROM meton_ledger.cash_order_attempts WHERE native_order=OLD.id) THEN';
BEGIN
    IF cardinality(string_to_array(src,marker))<>2 THEN RAISE EXCEPTION 'unexpected native order guard'; END IF;
    EXECUTE replace(src,marker,$allow$
    IF TG_OP='UPDATE' AND OLD.order_type='meton_purchase' AND pg_trigger_depth()=2 AND current_setting('session_replication_role')='origin'
        AND (to_jsonb(NEW)-ARRAY['status','payment_trade_no','paid_at','completed_at','updated_at'])=
            (to_jsonb(OLD)-ARRAY['status','payment_trade_no','paid_at','completed_at','updated_at'])
        AND EXISTS(SELECT FROM meton_ledger.cash_payments p WHERE p.native_order=NEW.id AND p.channel_transaction=NEW.payment_trade_no
            AND p.paid_at=NEW.paid_at AND (
                (OLD.status='PENDING' AND NEW.status='PAID' AND NEW.completed_at IS NULL) OR
                (OLD.status='PAID' AND NEW.status='COMPLETED' AND NEW.completed_at IS NOT NULL AND OLD.paid_at=NEW.paid_at
                 AND OLD.payment_trade_no=NEW.payment_trade_no AND EXISTS(SELECT FROM meton_ledger.cash_parts part
                     JOIN meton_ledger.events e ON e.event_id=part.credit_event WHERE part.payment_id=p.payment_id
                     AND part.basis='purchased_source' AND e.recorded_at=NEW.completed_at AND e.posting_xid=pg_current_xact_id()))))
        THEN RETURN NEW; END IF;
    $allow$||marker);
END $native_guard$;

CREATE FUNCTION meton_ledger.sync_native_cash_status() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF TG_TABLE_NAME='cash_payments' THEN
        UPDATE public.payment_orders SET status='PAID',payment_trade_no=NEW.channel_transaction,paid_at=NEW.paid_at,updated_at=clock_timestamp()
            WHERE id=NEW.native_order AND status='PENDING';
    ELSIF NEW.basis='purchased_source' THEN
        UPDATE public.payment_orders o SET status='COMPLETED',completed_at=e.recorded_at,updated_at=clock_timestamp()
            FROM meton_ledger.events e,meton_ledger.cash_payments p WHERE o.id=NEW.native_order AND o.status='PAID'
            AND p.payment_id=NEW.payment_id AND o.payment_trade_no=p.channel_transaction AND e.event_id=NEW.credit_event;
        IF NOT FOUND THEN RAISE EXCEPTION 'original payment not ready for fulfilment' USING ERRCODE='23514'; END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER reflect_original_payment AFTER INSERT ON meton_ledger.cash_payments
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.sync_native_cash_status();
CREATE TRIGGER reflect_original_purchase AFTER INSERT ON meton_ledger.cash_parts
    FOR EACH ROW WHEN (NEW.basis='purchased_source') EXECUTE FUNCTION meton_ledger.sync_native_cash_status();
ALTER TABLE meton_ledger.cash_payments ENABLE ALWAYS TRIGGER reflect_original_payment;
ALTER TABLE meton_ledger.cash_parts ENABLE ALWAYS TRIGGER reflect_original_purchase;
REVOKE ALL ON FUNCTION meton_ledger.sync_native_cash_status() FROM PUBLIC;
