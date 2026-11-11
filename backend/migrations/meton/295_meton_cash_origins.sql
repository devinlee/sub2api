-- 订单沿原支付模块，额度沿原来源账本。仅登记现金身份和必要关联，不授权运行角色写表。
-- 组合外键防止用另一账号的原生订单、另一份实付或赠送事件拼出合法的退款目标。
CREATE UNIQUE INDEX meton_cash_native_identity ON public.payment_orders(id,user_id,out_trade_no);
CREATE UNIQUE INDEX meton_cash_managed_identity ON public.meton_managed_creations(source_marker,remote_user);
CREATE UNIQUE INDEX meton_cash_credit_identity ON meton_ledger.events(event_id,source_marker,kind,origin_ref);

CREATE TABLE meton_ledger.cash_orders (
    native_order bigint PRIMARY KEY,
    source_marker uuid NOT NULL,
    remote_user bigint NOT NULL,
    intent_id uuid NOT NULL UNIQUE,
    params_hash text NOT NULL CHECK (params_hash ~ '^[0-9a-f]{64}$'),
    channel text NOT NULL CHECK (channel = 'wechatpay'),
    cash_environment text NOT NULL CHECK (cash_environment IN ('isolated','live')),
    merchant_id text NOT NULL CHECK (merchant_id ~ '^[0-9]{1,32}$'),
    app_id text NOT NULL CHECK (length(app_id) BETWEEN 1 AND 32),
    out_trade_no text NOT NULL CHECK (out_trade_no ~ '^[A-Za-z0-9_-]{1,32}$'),
    currency text NOT NULL CHECK (currency = 'CNY'),
    price_version text NOT NULL CHECK (length(price_version) BETWEEN 1 AND 120),
    unit text NOT NULL CHECK (unit ~ '^[A-Za-z0-9_.-]{1,120}$'),
    price_fen bigint NOT NULL CHECK (price_fen BETWEEN 1000 AND 2147483647),
    units_per_yuan numeric(20,8) NOT NULL CHECK (units_per_yuan > 0 AND units_per_yuan <= 999999999999.99999999),
    credit_units numeric(20,8) NOT NULL CHECK (credit_units > 0 AND credit_units <= 999999999999.99999999),
    created_at timestamptz NOT NULL CHECK (isfinite(created_at)),
    expires_at timestamptz NOT NULL CHECK (isfinite(expires_at) AND expires_at > created_at),
    CHECK (credit_units = round(price_fen::numeric * units_per_yuan / 100, 8)),
    FOREIGN KEY (native_order,remote_user,out_trade_no) REFERENCES public.payment_orders(id,user_id,out_trade_no),
    FOREIGN KEY (source_marker,remote_user) REFERENCES public.meton_managed_creations(source_marker,remote_user),
    UNIQUE (channel,cash_environment,merchant_id,out_trade_no),
    UNIQUE (native_order,source_marker,channel,cash_environment,merchant_id)
);

-- 投递号、签名、应用部署名和恢复代次均不是实付身份。一张原单允许留下多笔确实不同的实付。
CREATE TABLE meton_ledger.cash_payments (
    payment_id uuid PRIMARY KEY, native_order bigint NOT NULL, source_marker uuid NOT NULL,
    channel text NOT NULL, cash_environment text NOT NULL, merchant_id text NOT NULL,
    channel_transaction text NOT NULL CHECK (length(channel_transaction) BETWEEN 1 AND 64),
    order_fen bigint NOT NULL CHECK (order_fen > 0), payer_fen bigint NOT NULL CHECK (payer_fen >= 0),
    currency text NOT NULL CHECK (currency = 'CNY'), payer_currency text NOT NULL CHECK (payer_currency = 'CNY'),
    paid_at timestamptz NOT NULL CHECK (isfinite(paid_at)),
    FOREIGN KEY (native_order,source_marker,channel,cash_environment,merchant_id)
        REFERENCES meton_ledger.cash_orders(native_order,source_marker,channel,cash_environment,merchant_id),
    UNIQUE (channel,cash_environment,merchant_id,channel_transaction),
    UNIQUE (payment_id,native_order,source_marker)
);

-- 处置版本属于原实付。撤回、迟到结算、换主和退款认领都必须锁同一行并比较此前读到的版本。
CREATE TABLE meton_ledger.cash_payment_dispositions (
    payment_id uuid PRIMARY KEY REFERENCES meton_ledger.cash_payments,
    version bigint NOT NULL CHECK (version > 0),
    state text NOT NULL CHECK (state IN ('received','ready','restricted','resolved'))
);
CREATE FUNCTION meton_ledger.advance_cash_disposition() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF TG_OP='DELETE' OR NEW.payment_id IS DISTINCT FROM OLD.payment_id
        OR NEW.version<>OLD.version+1 THEN
        RAISE EXCEPTION 'original payment disposition version required' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER advance_cash_disposition BEFORE UPDATE OR DELETE ON meton_ledger.cash_payment_dispositions
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.advance_cash_disposition();
ALTER TABLE meton_ledger.cash_payment_dispositions ENABLE ALWAYS TRIGGER advance_cash_disposition;
-- 双向延迟外键保证每笔实付与首个处置在同一事务落地。
ALTER TABLE meton_ledger.cash_payments ADD FOREIGN KEY (payment_id)
    REFERENCES meton_ledger.cash_payment_dispositions(payment_id) DEFERRABLE INITIALLY DEFERRED;

-- 分开记录同一实付的份额。已履约份额只能指向本份额在原账号上的购买来源。
-- 未履约份额只占原现金，不生成可用额度；份额累计上限由原付款行锁下的受控命令核对。
CREATE TABLE meton_ledger.cash_parts (
    part_id uuid PRIMARY KEY, payment_id uuid NOT NULL, native_order bigint NOT NULL, source_marker uuid NOT NULL,
    basis text NOT NULL CHECK (basis IN ('purchased_source','unposted_cash')),
    basis_fen bigint NOT NULL CHECK (basis_fen > 0),
    credit_event uuid UNIQUE, credit_kind text GENERATED ALWAYS AS ('purchase'::text) STORED,
    CHECK ((basis = 'purchased_source') = (credit_event IS NOT NULL)),
    FOREIGN KEY (payment_id,native_order,source_marker) REFERENCES meton_ledger.cash_payments(payment_id,native_order,source_marker),
    FOREIGN KEY (credit_event,source_marker,credit_kind,part_id)
        REFERENCES meton_ledger.events(event_id,source_marker,kind,origin_ref),
    UNIQUE (part_id,native_order,basis)
);
CREATE UNIQUE INDEX meton_cash_one_fulfilment ON meton_ledger.cash_parts(native_order) WHERE basis='purchased_source';

-- 一份确认产生一个永久退款号，同额的第二份确认有独立身份。结果未知及待扣回仍占原单的唯一未决位置。
CREATE TABLE meton_ledger.cash_refunds (
    refund_id uuid PRIMARY KEY, intent_id uuid NOT NULL UNIQUE,
    out_refund_no text GENERATED ALWAYS AS ('R' || replace(refund_id::text,'-','')) STORED UNIQUE,
    native_order bigint NOT NULL, part_id uuid NOT NULL, basis text NOT NULL,
    params_hash text NOT NULL CHECK (params_hash ~ '^[0-9a-f]{64}$'),
    expected_version bigint NOT NULL CHECK (expected_version > 0),
    requested_fen bigint NOT NULL CHECK (requested_fen > 0),
    requested_units numeric(20,8),
    CHECK ((basis='purchased_source' AND requested_units IS NOT NULL AND requested_units > 0 AND requested_units <= 999999999999.99999999)
        OR (basis='unposted_cash' AND requested_units IS NULL)),
    phase text NOT NULL CHECK (phase IN
        ('held','possibly_sent','unknown','cash_confirmed','review','settled','released')),
    disposition_version bigint NOT NULL DEFAULT 1 CHECK (disposition_version > 0),
    FOREIGN KEY (part_id,native_order,basis) REFERENCES meton_ledger.cash_parts(part_id,native_order,basis)
);
CREATE UNIQUE INDEX meton_cash_one_open_refund ON meton_ledger.cash_refunds(native_order)
    WHERE phase NOT IN ('settled','released');

CREATE FUNCTION meton_ledger.advance_cash_refund() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF OLD.phase IN ('settled','released') OR NEW.disposition_version<>OLD.disposition_version+1 THEN
        RAISE EXCEPTION 'original refund already closed or stale version' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER advance_cash_refund BEFORE UPDATE ON meton_ledger.cash_refunds
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.advance_cash_refund();
ALTER TABLE meton_ledger.cash_refunds ENABLE ALWAYS TRIGGER advance_cash_refund;

CREATE TRIGGER immutable_cash_order BEFORE UPDATE OR DELETE ON meton_ledger.cash_orders
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TRIGGER immutable_cash_payment BEFORE UPDATE OR DELETE ON meton_ledger.cash_payments
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TRIGGER immutable_cash_basis BEFORE UPDATE OR DELETE ON meton_ledger.cash_parts
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
CREATE TRIGGER immutable_refund_origin BEFORE UPDATE OF refund_id,intent_id,native_order,part_id,basis,params_hash,expected_version,requested_fen,requested_units
    OR DELETE ON meton_ledger.cash_refunds FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_orders ENABLE ALWAYS TRIGGER immutable_cash_order;
ALTER TABLE meton_ledger.cash_payments ENABLE ALWAYS TRIGGER immutable_cash_payment;
ALTER TABLE meton_ledger.cash_parts ENABLE ALWAYS TRIGGER immutable_cash_basis;
ALTER TABLE meton_ledger.cash_refunds ENABLE ALWAYS TRIGGER immutable_refund_origin;
REVOKE ALL ON meton_ledger.cash_orders,meton_ledger.cash_payments,meton_ledger.cash_payment_dispositions,
    meton_ledger.cash_parts,meton_ledger.cash_refunds FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.advance_cash_disposition(), meton_ledger.advance_cash_refund() FROM PUBLIC;
