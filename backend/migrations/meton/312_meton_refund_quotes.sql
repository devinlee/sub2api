-- 退款仍归原订单。历史来源引用 S2 截点的订单，不能为兼容外键补造新的购买、付款或可消费额度。
ALTER TABLE meton_ledger.cash_refunds ALTER COLUMN part_id DROP NOT NULL, ADD COLUMN legacy_cutoff uuid,
    ADD CHECK((legacy_cutoff IS NULL)=(part_id IS NOT NULL)),
    ADD FOREIGN KEY(legacy_cutoff,native_order) REFERENCES meton_ledger.legacy_cash_handoffs(cutoff,native_order);
DROP TRIGGER immutable_refund_origin ON meton_ledger.cash_refunds;
CREATE TRIGGER immutable_refund_origin BEFORE UPDATE OF refund_id,intent_id,native_order,part_id,legacy_cutoff,basis,params_hash,expected_version,requested_fen,requested_units
    OR DELETE ON meton_ledger.cash_refunds FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_refunds ENABLE ALWAYS TRIGGER immutable_refund_origin;

-- 已终结的旧记录若尚缺资金恢复凭证，不能仅凭终态文字受理下一次退款。完成写入归后续实际释放和结清事务。
CREATE TABLE meton_ledger.cash_refund_recoveries(
    refund_id uuid PRIMARY KEY REFERENCES meton_ledger.cash_refunds, terminal_version bigint NOT NULL CHECK(terminal_version>0),
    phase text NOT NULL CHECK(phase IN ('released','settled')),confirmed_fen bigint NOT NULL CHECK(confirmed_fen>=0),
    confirmed_units numeric(20,8) NOT NULL CHECK(confirmed_units>=0),evidence bytea NOT NULL CHECK(octet_length(evidence)=32),
    CHECK(phase<>'released' OR (confirmed_fen=0 AND confirmed_units=0))
);
CREATE TRIGGER immutable_refund_recovery BEFORE UPDATE OR DELETE ON meton_ledger.cash_refund_recoveries
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_refund_recoveries ENABLE ALWAYS TRIGGER immutable_refund_recovery;

-- S2 原有批次的余额和 H／R 仍由同一事务写。记录其变动代次，避免额度占用后释放、数值恰好回到旧报价的 ABA。
CREATE TABLE meton_ledger.refund_lot_versions(credit_event uuid PRIMARY KEY REFERENCES meton_ledger.lots,version bigint NOT NULL CHECK(version>0));
CREATE FUNCTION meton_ledger.advance_refund_lot_version() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    INSERT INTO meton_ledger.refund_lot_versions VALUES(NEW.credit_event,1) ON CONFLICT(credit_event)
        DO UPDATE SET version=meton_ledger.refund_lot_versions.version+1;
    RETURN NEW;
END $$;
CREATE TRIGGER refund_lot_version AFTER UPDATE OF remaining,held,refund_held ON meton_ledger.lots
    FOR EACH ROW WHEN(NEW.refundable AND (NEW.remaining,NEW.held,NEW.refund_held) IS DISTINCT FROM (OLD.remaining,OLD.held,OLD.refund_held))
    EXECUTE FUNCTION meton_ledger.advance_refund_lot_version();
ALTER TABLE meton_ledger.lots ENABLE ALWAYS TRIGGER refund_lot_version;

CREATE TABLE meton_ledger.cash_refund_quotes(
    quote_id uuid PRIMARY KEY,source_marker uuid NOT NULL REFERENCES public.meton_managed_creations(source_marker),generation bigint NOT NULL,
    request jsonb NOT NULL,snapshot jsonb NOT NULL,outcome jsonb NOT NULL,issued_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,
    CHECK(isfinite(issued_at) AND isfinite(expires_at) AND issued_at<expires_at)
);
CREATE TRIGGER immutable_refund_quote BEFORE UPDATE OR DELETE ON meton_ledger.cash_refund_quotes
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_refund_quotes ENABLE ALWAYS TRIGGER immutable_refund_quote;
REVOKE ALL ON meton_ledger.cash_refund_recoveries,meton_ledger.refund_lot_versions,meton_ledger.cash_refund_quotes FROM PUBLIC;

CREATE FUNCTION meton_ledger.require_refund_owner(owner jsonb) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF owner->>'source_system' IS DISTINCT FROM meton_ledger.notification_system_id() OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin'
        OR NOT EXISTS(SELECT FROM public.meton_managed_fence f JOIN public.meton_managed_creations m
        ON (f.environment,f.source,f.epoch)=(m.environment,m.source,m.epoch) WHERE f.singleton AND f.enabled AND
        (m.environment,m.source,m.epoch,m.meton_user,m.account,m.operation,m.dispatch,m.remote_user,m.source_marker)=
        (owner->>'environment',owner->>'source',(owner->>'epoch')::bigint,(owner->>'user')::uuid,(owner->>'account')::uuid,
         (owner->>'creation')::uuid,(owner->>'dispatch')::uuid,(owner->>'remote_user')::bigint,(owner->>'source_marker')::uuid)) THEN
        RAISE EXCEPTION 'refund owner unavailable' USING ERRCODE='42501'; END IF;
    IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid='meton_ledger.lots'::regclass AND tgname='refund_lot_version'
        AND tgenabled='A' AND tgfoid='meton_ledger.advance_refund_lot_version()'::regprocedure) THEN
        RAISE EXCEPTION 'refund quote version guard unavailable' USING ERRCODE='55000'; END IF;
END $$;

-- 金额按最小货币单位累计四舍五入，沿原生正数舍入规则。整数除法避免小数先舍入、再次进位。
CREATE FUNCTION meton_ledger.refund_cumulative_fen(face numeric,original_units numeric,cumulative_units numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog,pg_temp AS $$
    SELECT div(2*face*(cumulative_units*100000000)+(original_units*100000000),2*(original_units*100000000))
$$;

CREATE FUNCTION meton_ledger.original_refund_snapshot(owner jsonb,order_id bigint,part_ref uuid,cutoff_ref uuid,basis_name text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid:=(owner->>'source_marker')::uuid; part meton_ledger.cash_parts; pay meton_ledger.cash_payments;
    disposition meton_ledger.cash_payment_dispositions; event meton_ledger.events; lot meton_ledger.lots;
    history jsonb; historic_source jsonb; face numeric; payment_cap numeric; original_units numeric; credit uuid; lot_version bigint:=0;
    available numeric:=0; retired_fen numeric; retired_units numeric; payment_returned numeric; refund_version bigint;
BEGIN
    IF num_nonnulls(part_ref,cutoff_ref)<>1 OR basis_name NOT IN ('purchased_source','unposted_cash') OR basis_name IS NULL THEN
        RAISE EXCEPTION 'original refund target required' USING ERRCODE='22023'; END IF;
    IF cutoff_ref IS NULL THEN
        SELECT * INTO part FROM meton_ledger.cash_parts WHERE (native_order,source_marker,part_id)=(order_id,marker,part_ref);
        IF NOT FOUND THEN RAISE EXCEPTION 'unknown original refund target' USING ERRCODE='42501'; END IF;
        IF part.basis<>basis_name THEN RAISE EXCEPTION 'refund basis differs' USING ERRCODE='22023'; END IF;
        SELECT * INTO STRICT pay FROM meton_ledger.cash_payments WHERE (native_order,source_marker,payment_id)=(order_id,marker,part.payment_id);
        SELECT * INTO STRICT disposition FROM meton_ledger.cash_payment_dispositions WHERE payment_id=pay.payment_id;
        IF pay.currency<>'CNY' OR pay.payer_currency<>'CNY' OR EXISTS(SELECT FROM meton_ledger.cash_refund_observations signal
            WHERE signal.native_order=order_id AND signal.transaction_id=pay.channel_transaction) OR EXISTS(SELECT FROM meton_ledger.cash_payment_conflicts c
            JOIN meton_ledger.cash_payments disputed USING(payment_id) WHERE disputed.native_order=order_id OR
                (c.claimed_intent,c.claimed_marker)=(SELECT intent_id,source_marker FROM meton_ledger.cash_orders WHERE native_order=order_id)) THEN
            RETURN jsonb_build_object('state','review'); END IF;
        IF (basis_name='unposted_cash' AND (part.credit_event IS NOT NULL OR disposition.state<>'restricted')) OR
            (basis_name='purchased_source' AND (part.credit_event IS NULL OR disposition.state<>'resolved')) THEN
            RETURN jsonb_build_object('state','review'); END IF;
        face:=part.basis_fen;payment_cap:=pay.payer_fen;credit:=part.credit_event;
        IF credit IS NOT NULL THEN
            SELECT * INTO STRICT event FROM meton_ledger.events WHERE event_id=credit AND source_marker=marker AND kind='purchase' AND origin_ref=part.part_id;
            original_units:=event.amount;
        END IF;
    ELSE
        history:=meton_ledger.read_legacy_cash_order(owner,cutoff_ref,order_id);
        IF history IS NULL THEN RAISE EXCEPTION 'unknown original refund target' USING ERRCODE='42501'; END IF;
        IF history->>'state' NOT IN ('paid_unfulfilled','source_opened') OR NOT (history->>'hasOrderReferences')::boolean THEN
            RETURN jsonb_build_object('state','review'); END IF;
        IF history->>'basis' IS DISTINCT FROM basis_name THEN RAISE EXCEPTION 'refund basis differs' USING ERRCODE='22023'; END IF;
        IF basis_name='unposted_cash' THEN face:=(history->>'verifiedPayAmount')::numeric*100;
        ELSE
            historic_source:=history->'sourceBasis';
            IF historic_source->>'denomination' IS DISTINCT FROM 'CNY' THEN RETURN jsonb_build_object('state','review'); END IF;
            face:=(historic_source->>'faceValue')::numeric*100;original_units:=(historic_source->>'originalUnits')::numeric;
            credit:=(historic_source->>'creditEvent')::uuid;
        END IF;
        payment_cap:=face;
    END IF;
    IF face IS NULL OR face<>trunc(face) OR face<=0 OR face>payment_cap OR face>9223372036854775807 OR basis_name='purchased_source' AND coalesce(original_units,0)<=0 THEN
        RETURN jsonb_build_object('state','review'); END IF;
    face:=trunc(face);payment_cap:=trunc(payment_cap);
    IF EXISTS(SELECT FROM meton_ledger.cash_refunds WHERE native_order=order_id AND phase NOT IN ('released','settled')) THEN
        RETURN jsonb_build_object('state','refund_pending'); END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_refunds r LEFT JOIN meton_ledger.cash_refund_recoveries w USING(refund_id)
        WHERE r.native_order=order_id AND (w.refund_id IS NULL OR (w.phase,w.terminal_version,w.confirmed_fen,w.confirmed_units)
        IS DISTINCT FROM (r.phase,r.disposition_version,CASE WHEN r.phase='settled' THEN r.requested_fen ELSE 0 END,
            CASE WHEN r.phase='settled' THEN coalesce(r.requested_units,0) ELSE 0 END))) THEN
        RETURN jsonb_build_object('state','recovery_review'); END IF;
    SELECT coalesce(sum(w.confirmed_fen) FILTER(WHERE r.part_id IS NOT DISTINCT FROM part_ref AND r.legacy_cutoff IS NOT DISTINCT FROM cutoff_ref),0),
        coalesce(sum(w.confirmed_units) FILTER(WHERE r.part_id IS NOT DISTINCT FROM part_ref AND r.legacy_cutoff IS NOT DISTINCT FROM cutoff_ref),0),
        coalesce(sum(w.confirmed_fen) FILTER(WHERE (pay.payment_id IS NOT NULL AND prior.payment_id=pay.payment_id) OR
            (cutoff_ref IS NOT NULL AND r.legacy_cutoff=cutoff_ref)),0),count(*)
        INTO retired_fen,retired_units,payment_returned,refund_version FROM meton_ledger.cash_refunds r
        JOIN meton_ledger.cash_refund_recoveries w USING(refund_id) LEFT JOIN meton_ledger.cash_parts prior ON prior.part_id=r.part_id WHERE r.native_order=order_id;
    IF retired_fen>face OR payment_returned>payment_cap OR retired_units>coalesce(original_units,0)
       OR basis_name='purchased_source' AND retired_fen<>meton_ledger.refund_cumulative_fen(face,original_units,retired_units) THEN
        RETURN jsonb_build_object('state','review'); END IF;
    IF credit IS NOT NULL THEN
        SELECT * INTO STRICT lot FROM meton_ledger.lots WHERE credit_event=credit;
        IF NOT lot.refundable OR lot.denomination<>'CNY' THEN RETURN jsonb_build_object('state','review'); END IF;
        available:=least(lot.remaining-lot.held-lot.refund_held,original_units-retired_units);
        SELECT coalesce((SELECT version FROM meton_ledger.refund_lot_versions WHERE credit_event=credit),0) INTO lot_version;
    END IF;
    RETURN jsonb_build_object('state','ready','basis',basis_name,'currency','CNY','faceFen',face::text,'paymentCapFen',payment_cap::text,
        'partReturnedFen',retired_fen::text,'paymentReturnedFen',payment_returned::text,'retiredUnits',retired_units::text,
        'originalUnits',original_units::text,'availableUnits',available::text,'creditEvent',credit,'lotVersion',lot_version,'refundCount',refund_version,
        'dispositionVersion',disposition.version,'payment',pay.payment_id,'historyProof',history->>'proofHash');
END $$;

CREATE FUNCTION meton_ledger.refund_offer(snapshot jsonb,units numeric,fen bigint) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE amount numeric; face numeric:=(snapshot->>'faceFen')::numeric; part_used numeric:=(snapshot->>'partReturnedFen')::numeric;
    payment_left numeric:=(snapshot->>'paymentCapFen')::numeric-(snapshot->>'paymentReturnedFen')::numeric;
BEGIN
    IF snapshot->>'state'<>'ready' THEN RETURN jsonb_build_object('state',snapshot->>'state'); END IF;
    IF snapshot->>'basis'='purchased_source' THEN
        IF units>(snapshot->>'availableUnits')::numeric THEN RETURN jsonb_build_object('state','insufficient'); END IF;
        amount:=meton_ledger.refund_cumulative_fen(face,(snapshot->>'originalUnits')::numeric,(snapshot->>'retiredUnits')::numeric+units)-part_used;
    ELSE amount:=fen; END IF;
    IF amount<1 THEN RETURN jsonb_build_object('state','below_minimum'); END IF;
    IF amount>least(face-part_used,payment_left) THEN RETURN jsonb_build_object('state','insufficient'); END IF;
    RETURN jsonb_build_object('state','quoted','currency','CNY','fen',amount::bigint,'units',units::text);
END $$;

-- 报价截止取受信来源接入层给出的原授权窗口。重放原报价不会延长有效期或生成退款，更换选择必须新取报价。
CREATE FUNCTION meton_ledger.quote_original_refund(owner jsonb,quote_ref uuid,order_id bigint,part_ref uuid,cutoff_ref uuid,
    basis_name text,wanted_units text,wanted_fen bigint,valid_until timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid:=(owner->>'source_marker')::uuid; generation bigint:=(owner->>'epoch')::bigint; params jsonb; shape jsonb; result jsonb;
    previous meton_ledger.cash_refund_quotes; now_at timestamptz:=clock_timestamp();
BEGIN
    PERFORM meton_ledger.require_cash_writer(owner->>'environment',owner->>'source',generation);
    PERFORM meton_ledger.require_refund_owner(owner);
    IF quote_ref IS NULL OR quote_ref='00000000-0000-0000-0000-000000000000'::uuid OR order_id IS NULL OR order_id<=0 OR num_nonnulls(part_ref,cutoff_ref)<>1
        OR NOT coalesce((basis_name='purchased_source' AND wanted_fen IS NULL AND wanted_units ~ '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$' AND wanted_units<>'0.00000000')
            OR (basis_name='unposted_cash' AND wanted_units IS NULL AND wanted_fen>0),false) THEN
        RAISE EXCEPTION 'invalid refund quote selection' USING ERRCODE='22023'; END IF;
    params:=jsonb_build_object('order',order_id,'part',part_ref,'cutoff',cutoff_ref,'basis',basis_name,'units',wanted_units,'fen',wanted_fen);
    -- 租期、恢复代次和渠道签名都不充当经济身份。相同报价请求并发只计算并保存首次快照。
    PERFORM pg_advisory_xact_lock(hashtextextended('refund-quote/'||quote_ref::text,0));
    SELECT * INTO previous FROM meton_ledger.cash_refund_quotes WHERE quote_id=quote_ref;
    IF FOUND THEN
        IF previous.source_marker<>marker THEN RAISE EXCEPTION 'unknown refund quote' USING ERRCODE='42501'; END IF;
        IF previous.request<>params THEN RAISE EXCEPTION 'refund quote parameters changed' USING ERRCODE='23505'; END IF;
        IF previous.generation<>generation THEN RETURN jsonb_build_object('state','stale_quote','quote',quote_ref); END IF;
        IF previous.expires_at<=clock_timestamp() THEN RETURN jsonb_build_object('state','expired','quote',quote_ref); END IF;
        RETURN previous.outcome;
    END IF;
    IF valid_until IS NULL OR NOT isfinite(valid_until) OR valid_until<=clock_timestamp() THEN RAISE EXCEPTION 'refund quote window expired' USING ERRCODE='55000'; END IF;
    shape:=meton_ledger.original_refund_snapshot(owner,order_id,part_ref,cutoff_ref,basis_name);
    result:=meton_ledger.refund_offer(shape,wanted_units::numeric,wanted_fen)||jsonb_build_object('quote',quote_ref,'order',order_id,
        'basis',basis_name,'basisVersion',encode(sha256(convert_to(shape::text,'UTF8')),'hex'),'expiresAt',valid_until);
    IF valid_until<=clock_timestamp() THEN RAISE EXCEPTION 'refund quote window expired' USING ERRCODE='55000'; END IF;
    INSERT INTO meton_ledger.cash_refund_quotes VALUES(quote_ref,marker,generation,params,shape,result,now_at,valid_until);
    RETURN result;
END $$;
CREATE FUNCTION meton_ledger.read_original_refund_quote(owner jsonb,quote_ref uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE previous meton_ledger.cash_refund_quotes;
BEGIN
    PERFORM meton_ledger.require_refund_owner(owner);
    SELECT * INTO previous FROM meton_ledger.cash_refund_quotes WHERE quote_id=quote_ref AND source_marker=(owner->>'source_marker')::uuid;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF previous.generation<>(owner->>'epoch')::bigint THEN RETURN jsonb_build_object('state','stale_quote','quote',quote_ref); END IF;
    IF previous.expires_at<=clock_timestamp() THEN RETURN jsonb_build_object('state','expired','quote',quote_ref); END IF;
    RETURN previous.outcome;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.require_refund_owner(jsonb),meton_ledger.advance_refund_lot_version(),
    meton_ledger.refund_cumulative_fen(numeric,numeric,numeric),meton_ledger.original_refund_snapshot(jsonb,bigint,uuid,uuid,text),
    meton_ledger.refund_offer(jsonb,numeric,bigint),meton_ledger.quote_original_refund(jsonb,uuid,bigint,uuid,uuid,text,text,bigint,timestamptz),
    meton_ledger.read_original_refund_quote(jsonb,uuid) FROM PUBLIC;
