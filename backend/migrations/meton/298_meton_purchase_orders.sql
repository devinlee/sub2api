-- 渠道及商户由部署方登记。保留 295 原订单的渠道、商户和应用，历史路由不会自行发布新的报价。
CREATE TABLE meton_ledger.cash_routes (
    channel text NOT NULL CHECK(channel ~ '^[a-z][a-z0-9_.-]{0,47}$'),
    cash_environment text NOT NULL CHECK(cash_environment IN ('isolated','live')),
    merchant_id text NOT NULL CHECK(length(merchant_id) BETWEEN 1 AND 128 AND merchant_id=btrim(merchant_id)),
    app_id text NOT NULL CHECK(length(app_id) BETWEEN 1 AND 128 AND app_id=btrim(app_id)),
    native_method text NOT NULL CHECK(native_method ~ '^[a-z][a-z0-9_.-]{0,29}$'),
    PRIMARY KEY(channel,cash_environment,merchant_id,app_id)
);
INSERT INTO meton_ledger.cash_routes
    SELECT DISTINCT channel,cash_environment,merchant_id,app_id,'wxpay' FROM meton_ledger.cash_orders;
ALTER TABLE meton_ledger.cash_orders DROP CONSTRAINT cash_orders_channel_check,
    DROP CONSTRAINT cash_orders_merchant_id_check, DROP CONSTRAINT cash_orders_app_id_check,
    ADD FOREIGN KEY(channel,cash_environment,merchant_id,app_id)
        REFERENCES meton_ledger.cash_routes(channel,cash_environment,merchant_id,app_id);

-- 版本和规则一经发布保持不变。每个商品和渠道只从当前来源代次的最新开放版本取得新报价。
CREATE TABLE meton_ledger.cash_offers (
    offer_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    environment text NOT NULL, source text NOT NULL, epoch bigint NOT NULL CHECK(epoch>0),
    product text NOT NULL CHECK(product ~ '^[a-z][a-z0-9_.-]{0,79}$'),
    channel text NOT NULL, cash_environment text NOT NULL, merchant_id text NOT NULL, app_id text NOT NULL,
    revision bigint NOT NULL CHECK(revision>0), price_version text NOT NULL CHECK(price_version ~ '^[A-Za-z0-9_.-]{1,120}$'),
    enabled boolean NOT NULL, unit text NOT NULL CHECK(unit ~ '^[A-Za-z0-9_.-]{1,120}$'),
    currency text NOT NULL CHECK(currency='CNY'),
    min_fen bigint NOT NULL CHECK(min_fen>=1000), max_fen bigint NOT NULL CHECK(max_fen BETWEEN min_fen AND 2147483647),
    units_per_yuan numeric(20,8) NOT NULL CHECK(units_per_yuan>0 AND units_per_yuan<=999999999999.99999999 AND
        round(max_fen::numeric*units_per_yuan/100,8)<=999999999999.99999999 AND round(min_fen::numeric*units_per_yuan/100,8)>0),
    payment_seconds integer NOT NULL CHECK(payment_seconds BETWEEN 60 AND 86400),
    FOREIGN KEY(channel,cash_environment,merchant_id,app_id) REFERENCES meton_ledger.cash_routes,
    UNIQUE(environment,source,epoch,product,channel,revision), UNIQUE(environment,source,epoch,product,channel,price_version)
);
CREATE FUNCTION meton_ledger.check_cash_offer_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND
        (environment,source,epoch)=(NEW.environment,NEW.source,NEW.epoch) FOR UPDATE;
    IF NOT FOUND OR NEW.revision<>(SELECT coalesce(max(revision),0)+1 FROM meton_ledger.cash_offers WHERE
        (environment,source,epoch,product,channel)=(NEW.environment,NEW.source,NEW.epoch,NEW.product,NEW.channel)) THEN
        RAISE EXCEPTION 'original offer revision unavailable' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER publish_offer BEFORE INSERT ON meton_ledger.cash_offers FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_cash_offer_revision();
ALTER TABLE meton_ledger.cash_offers ENABLE ALWAYS TRIGGER publish_offer;

CREATE UNIQUE INDEX checkout_handoff_owner ON meton_ledger.checkout_handoffs(intent_id,source_marker);
CREATE TABLE meton_ledger.purchase_quotes (
    quote_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), intent_id uuid NOT NULL UNIQUE, source_marker uuid NOT NULL,
    offer_id uuid NOT NULL REFERENCES meton_ledger.cash_offers, price_fen bigint NOT NULL CHECK(price_fen BETWEEN 1000 AND 2147483647),
    issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL CHECK(isfinite(expires_at) AND expires_at>issued_at),
    FOREIGN KEY(intent_id,source_marker) REFERENCES meton_ledger.checkout_handoffs(intent_id,source_marker),
    UNIQUE(quote_id,intent_id,source_marker)
);
CREATE UNIQUE INDEX cash_order_attempt_owner ON meton_ledger.cash_orders(native_order,intent_id,source_marker);
CREATE TABLE meton_ledger.cash_order_attempts (
    attempt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), native_order bigint NOT NULL UNIQUE,
    intent_id uuid NOT NULL UNIQUE, quote_id uuid NOT NULL UNIQUE, source_marker uuid NOT NULL,
    creating_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    created_at timestamptz NOT NULL, expires_at timestamptz NOT NULL CHECK(isfinite(expires_at) AND expires_at>created_at),
    dispatch_id uuid UNIQUE, dispatched_at timestamptz, presentation jsonb,
    CHECK((dispatch_id IS NULL)=(dispatched_at IS NULL) AND (presentation IS NULL OR dispatch_id IS NOT NULL)),
    FOREIGN KEY(quote_id,intent_id,source_marker) REFERENCES meton_ledger.purchase_quotes(quote_id,intent_id,source_marker),
    FOREIGN KEY(native_order,intent_id,source_marker) REFERENCES meton_ledger.cash_orders(native_order,intent_id,source_marker)
        DEFERRABLE INITIALLY DEFERRED
);
DO $$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['cash_routes','cash_offers','purchase_quotes'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_record BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',t);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_record',t);
    END LOOP;
END $$;

-- 原资金门禁仍挡住直接写单。只有同一事务的已核验报价和付款尝试可以创建它们所指的那一行。
CREATE FUNCTION meton_ledger.guard_native_purchase() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF TG_OP<>'INSERT' AND EXISTS(SELECT FROM meton_ledger.cash_order_attempts WHERE native_order=OLD.id) THEN
        RAISE EXCEPTION 'managed order requires original transition' USING ERRCODE='23514'; END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    IF TG_OP='UPDATE' AND EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=OLD.user_id) THEN
        RAISE EXCEPTION 'managed order owner immutable' USING ERRCODE='23514'; END IF;
    IF TG_OP='INSERT' AND NEW.order_type='meton_purchase' AND pg_trigger_depth()=2 AND current_setting('session_replication_role')='origin'
        AND EXISTS(SELECT FROM meton_ledger.cash_order_attempts a JOIN meton_ledger.purchase_quotes q USING(quote_id,intent_id,source_marker)
            JOIN public.meton_managed_creations m USING(source_marker) JOIN meton_ledger.cash_offers f USING(offer_id)
            JOIN meton_ledger.cash_routes r USING(channel,cash_environment,merchant_id,app_id)
            WHERE a.creating_xid=pg_current_xact_id() AND a.native_order=NEW.id AND m.remote_user=NEW.user_id
            AND NEW.out_trade_no=replace(a.attempt_id::text,'-','') AND NEW.pay_amount=q.price_fen::numeric/100
            AND NEW.amount=NEW.pay_amount AND NEW.fee_rate=0 AND NEW.bonus_amount=0 AND NEW.status='PENDING'
            AND NEW.payment_type=r.native_method AND NEW.provider_key=r.native_method AND NEW.recharge_code=''
            AND NEW.payment_trade_no='' AND NEW.created_at=a.created_at AND NEW.expires_at=a.expires_at) THEN RETURN NEW; END IF;
    IF NEW.order_type='meton_purchase' OR EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=NEW.user_id) THEN
        RAISE EXCEPTION 'managed order requires accepted quote' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END $$;
DROP TRIGGER meton_s1_no_order ON public.payment_orders;
CREATE TRIGGER meton_s1_no_order BEFORE INSERT OR UPDATE OR DELETE ON public.payment_orders
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.guard_native_purchase();
ALTER TABLE public.payment_orders ENABLE ALWAYS TRIGGER meton_s1_no_order;

-- 现金订单沿用原生订单表。八位额度保存在快照；原生两位金额字段只表达本类订单的现金面值。
CREATE FUNCTION meton_ledger.record_native_purchase() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE q meton_ledger.purchase_quotes%ROWTYPE; f meton_ledger.cash_offers%ROWTYPE; method text; uid bigint;
    trade text:=replace(NEW.attempt_id::text,'-',''); digest text;
BEGIN
    SELECT * INTO STRICT q FROM meton_ledger.purchase_quotes WHERE quote_id=NEW.quote_id AND intent_id=NEW.intent_id AND source_marker=NEW.source_marker;
    SELECT * INTO STRICT f FROM meton_ledger.cash_offers WHERE offer_id=q.offer_id;
    SELECT native_method INTO STRICT method FROM meton_ledger.cash_routes WHERE
        (channel,cash_environment,merchant_id,app_id)=(f.channel,f.cash_environment,f.merchant_id,f.app_id);
    SELECT remote_user INTO STRICT uid FROM public.meton_managed_creations WHERE source_marker=q.source_marker;
    INSERT INTO public.payment_orders(id,user_id,user_email,user_name,amount,pay_amount,fee_rate,bonus_amount,recharge_code,
        out_trade_no,payment_type,provider_key,payment_trade_no,order_type,status,created_at,updated_at,expires_at)
        SELECT NEW.native_order,uid,email,coalesce(username,''),q.price_fen::numeric/100,q.price_fen::numeric/100,0,0,'',
               trade,method,method,'','meton_purchase','PENDING',NEW.created_at,NEW.created_at,NEW.expires_at
        FROM public.users WHERE id=uid;
    digest:=encode(sha256(convert_to(jsonb_build_array('purchase.v1',q.intent_id,q.quote_id,q.offer_id,
        f.product,f.channel,f.cash_environment,f.merchant_id,f.app_id,f.price_version,f.currency,q.price_fen)::text,'UTF8')),'hex');
    INSERT INTO meton_ledger.cash_orders(native_order,source_marker,remote_user,intent_id,params_hash,channel,cash_environment,
        merchant_id,app_id,out_trade_no,currency,price_version,unit,price_fen,units_per_yuan,credit_units,created_at,expires_at)
        VALUES(NEW.native_order,q.source_marker,uid,q.intent_id,digest,f.channel,f.cash_environment,f.merchant_id,f.app_id,trade,
        f.currency,f.price_version,f.unit,q.price_fen,f.units_per_yuan,round(q.price_fen::numeric*f.units_per_yuan/100,8),NEW.created_at,NEW.expires_at);
    RETURN NEW;
END $$;
CREATE TRIGGER record_native_purchase AFTER INSERT ON meton_ledger.cash_order_attempts FOR EACH ROW EXECUTE FUNCTION meton_ledger.record_native_purchase();
ALTER TABLE meton_ledger.cash_order_attempts ENABLE ALWAYS TRIGGER record_native_purchase;

-- 收银台选择参数首次绑定原意图。重试查回同一报价，不能以新价格或另一个账号重新解释。
CREATE FUNCTION meton_ledger.quote_purchase(o jsonb,d jsonb,b jsonb,i uuid,w bytea,product_id text,channel_id text,
    cash_currency text,fen bigint,deadline timestamptz) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE q meton_ledger.purchase_quotes%ROWTYPE; f meton_ledger.cash_offers%ROWTYPE; cutoff timestamptz;
BEGIN
    IF num_nulls(product_id,channel_id,cash_currency,fen,deadline)>0 OR cash_currency<>'CNY' OR fen NOT BETWEEN 1000 AND 2147483647 THEN
       RAISE EXCEPTION 'invalid purchase selection' USING ERRCODE='22023'; END IF;
    PERFORM meton_ledger.authorize_checkout_order(o,d,b,i,w,deadline);
    SELECT web_expires_at INTO STRICT cutoff FROM meton_ledger.checkout_handoffs WHERE intent_id=i FOR UPDATE;
    SELECT * INTO q FROM meton_ledger.purchase_quotes WHERE intent_id=i;
    IF FOUND THEN
        SELECT * INTO STRICT f FROM meton_ledger.cash_offers WHERE offer_id=q.offer_id;
        IF (f.product,f.channel,f.currency,q.price_fen) IS DISTINCT FROM (product_id,channel_id,cash_currency,fen) THEN
            RAISE EXCEPTION 'original quote differs' USING ERRCODE='23505'; END IF;
    ELSE
        SELECT * INTO f FROM meton_ledger.cash_offers WHERE environment=o->>'environment' AND source=o->>'source'
            AND epoch=(o->>'epoch')::bigint AND product=product_id AND channel=channel_id ORDER BY revision DESC LIMIT 1;
        IF NOT FOUND OR NOT f.enabled OR fen NOT BETWEEN f.min_fen AND f.max_fen OR f.currency<>cash_currency THEN
            RAISE EXCEPTION 'purchase offer unavailable' USING ERRCODE='22023'; END IF;
        INSERT INTO meton_ledger.purchase_quotes(intent_id,source_marker,offer_id,price_fen,issued_at,expires_at)
            VALUES(i,(o->>'source_marker')::uuid,f.offer_id,fen,clock_timestamp(),cutoff) RETURNING * INTO q;
    END IF;
    IF least(q.expires_at,deadline)<=clock_timestamp() THEN RAISE EXCEPTION 'quote expired' USING ERRCODE='55000'; END IF;
    RETURN q.quote_id;
END $$;

CREATE FUNCTION meton_ledger.commit_purchase(o jsonb,d jsonb,b jsonb,i uuid,w bytea,selected uuid,product_id text,
    channel_id text,cash_currency text,fen bigint,deadline timestamptz) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE q meton_ledger.purchase_quotes%ROWTYPE; f meton_ledger.cash_offers%ROWTYPE; result bigint; stamp timestamptz;
BEGIN
    PERFORM meton_ledger.authorize_checkout_order(o,d,b,i,w,deadline);
    SELECT * INTO q FROM meton_ledger.purchase_quotes WHERE intent_id=i AND source_marker=(o->>'source_marker')::uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'original quote required' USING ERRCODE='42501'; END IF;
    SELECT * INTO STRICT f FROM meton_ledger.cash_offers WHERE offer_id=q.offer_id;
    IF (q.quote_id,f.product,f.channel,f.currency,q.price_fen) IS DISTINCT FROM (selected,product_id,channel_id,cash_currency,fen) THEN
        RAISE EXCEPTION 'original purchase differs' USING ERRCODE='23505'; END IF;
    SELECT native_order INTO result FROM meton_ledger.cash_order_attempts WHERE intent_id=i;
    IF NOT FOUND THEN
        stamp:=date_trunc('second',clock_timestamp());
        IF q.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'original quote expired' USING ERRCODE='55000'; END IF;
        INSERT INTO meton_ledger.cash_order_attempts(native_order,intent_id,quote_id,source_marker,created_at,expires_at)
            VALUES(nextval(pg_get_serial_sequence('public.payment_orders','id')),i,q.quote_id,q.source_marker,stamp,stamp+make_interval(secs=>f.payment_seconds))
            RETURNING native_order INTO result;
    END IF;
    IF deadline<=clock_timestamp() THEN RAISE EXCEPTION 'purchase admission expired' USING ERRCODE='55000'; END IF;
    RETURN result;
END $$;

-- 唯一成功认领者在提交后才可联系渠道。已经可能外发的操作永远不按同号或新号重新派发。
CREATE FUNCTION meton_ledger.claim_purchase_dispatch(o jsonb,d jsonb,b jsonb,i uuid,w bytea,selected uuid,deadline timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE ticket uuid; stamp timestamptz;
BEGIN
    PERFORM meton_ledger.authorize_checkout_order(o,d,b,i,w,deadline);
    PERFORM 1 FROM meton_ledger.cash_order_attempts WHERE intent_id=i AND quote_id=selected AND source_marker=(o->>'source_marker')::uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'original payment attempt missing' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.authorize_checkout_order(o,d,b,i,w,deadline);
    stamp:=clock_timestamp();
    IF stamp>=deadline THEN RAISE EXCEPTION 'dispatch admission expired' USING ERRCODE='55000'; END IF;
    UPDATE meton_ledger.cash_order_attempts SET dispatch_id=gen_random_uuid(),dispatched_at=stamp
        WHERE intent_id=i AND dispatch_id IS NULL AND expires_at>stamp RETURNING dispatch_id INTO ticket;
    RETURN ticket;
END $$;

-- 晚到的受理回执只能归已派发的原请求。支付呈现与付款、额度到账各自独立。
CREATE FUNCTION meton_ledger.observe_purchase_dispatch(o jsonb,i uuid,ticket uuid,view_kind text,view_value text,deadline timestamptz)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_ledger.cash_order_attempts%ROWTYPE; observed jsonb;
BEGIN
    IF num_nulls(o,i,ticket,view_kind,view_value,deadline)>0 OR view_kind !~ '^[a-z][a-z0-9_.-]{0,31}$'
       OR octet_length(view_value) NOT BETWEEN 1 AND 2048 OR view_value ~ '[[:cntrl:]]' THEN
        RAISE EXCEPTION 'invalid payment presentation' USING ERRCODE='22023'; END IF;
    PERFORM 1 FROM public.meton_managed_fence WHERE singleton AND enabled AND
        (environment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint) FOR SHARE;
    IF NOT FOUND OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR
       current_setting('transaction_isolation')<>'read committed' OR deadline>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'dispatch source unavailable' USING ERRCODE='55000'; END IF;
    SELECT x.* INTO a FROM meton_ledger.cash_order_attempts x JOIN meton_ledger.checkout_handoffs h USING(intent_id,source_marker)
        WHERE x.intent_id=i AND h.origin=o AND x.dispatch_id=ticket FOR UPDATE OF x;
    IF NOT FOUND THEN RAISE EXCEPTION 'original dispatch missing' USING ERRCODE='42501'; END IF;
    IF deadline<=clock_timestamp() THEN RAISE EXCEPTION 'observation admission expired' USING ERRCODE='55000'; END IF;
    observed:=jsonb_build_object('kind',view_kind,'value',view_value);
    IF a.presentation IS NULL THEN UPDATE meton_ledger.cash_order_attempts SET presentation=observed WHERE attempt_id=a.attempt_id;
    ELSIF a.presentation IS DISTINCT FROM observed THEN RAISE EXCEPTION 'original dispatch observation differs' USING ERRCODE='23505'; END IF;
    RETURN true;
END $$;

-- 可在退出旧设备后按原账号查询已经受理的订单。此查询不返回支付码、派发认领或收银台会话秘密。
CREATE FUNCTION meton_ledger.read_original_purchase(o jsonb,i uuid,deadline timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE observed jsonb;
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR current_setting('transaction_read_only')<>'on'
       OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR deadline IS NULL
       OR deadline<=clock_timestamp() OR deadline>clock_timestamp()+interval '30 seconds' THEN
        RAISE EXCEPTION 'order query unavailable' USING ERRCODE='55000'; END IF;
    IF NOT EXISTS(SELECT FROM public.meton_managed_fence WHERE singleton AND enabled AND
         (environment,source,epoch)=(o->>'environment',o->>'source',(o->>'epoch')::bigint)) THEN
        RAISE EXCEPTION 'order source closed' USING ERRCODE='55000'; END IF;
    SELECT jsonb_build_object('intent',h.intent_id,'quote',q.quote_id,'product',f.product,'channel',f.channel,
        'environment',f.cash_environment,'merchant',f.merchant_id,'app',f.app_id,'priceVersion',f.price_version,
        'unit',f.unit,'priceFen',q.price_fen,'currency',f.currency,'creditUnits',round(q.price_fen::numeric*f.units_per_yuan/100,8)::text,
        'quoteExpiresAt',q.expires_at,'order',a.native_order,'outTradeNo',c.out_trade_no,'orderExpiresAt',c.expires_at,
        'attempt',CASE WHEN a.attempt_id IS NULL THEN 'quoted' WHEN a.dispatch_id IS NULL THEN 'prepared'
                       WHEN a.presentation IS NULL THEN 'possibly_sent' ELSE 'presented' END,
        'paymentConfirmed',EXISTS(SELECT FROM meton_ledger.cash_payments p WHERE p.native_order=a.native_order),
        'creditPosted',EXISTS(SELECT FROM meton_ledger.cash_parts p WHERE p.native_order=a.native_order AND p.basis='purchased_source' AND p.credit_event IS NOT NULL))
        INTO observed FROM meton_ledger.checkout_handoffs h JOIN meton_ledger.purchase_quotes q USING(intent_id,source_marker)
        JOIN meton_ledger.cash_offers f USING(offer_id) JOIN public.meton_managed_creations m USING(source_marker)
        JOIN public.users u ON u.id=m.remote_user LEFT JOIN meton_ledger.cash_order_attempts a USING(intent_id,quote_id,source_marker)
        LEFT JOIN meton_ledger.cash_orders c ON c.native_order=a.native_order
        WHERE h.intent_id=i AND h.origin=o AND u.status='active' AND u.deleted_at IS NULL
          AND (m.environment,m.source,m.epoch,m.meton_user,m.account,m.operation,m.dispatch,m.remote_user)=
              (o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'user')::uuid,(o->>'account')::uuid,
               (o->>'creation')::uuid,(o->>'dispatch')::uuid,(o->>'remote_user')::bigint);
    IF deadline<=clock_timestamp() THEN RAISE EXCEPTION 'order query expired' USING ERRCODE='55000'; END IF;
    RETURN observed;
END $$;

REVOKE ALL ON meton_ledger.cash_routes,meton_ledger.cash_offers,meton_ledger.purchase_quotes,meton_ledger.cash_order_attempts FROM PUBLIC;
REVOKE ALL ON FUNCTION meton_ledger.check_cash_offer_revision(),meton_ledger.guard_native_purchase(),meton_ledger.record_native_purchase(),
    meton_ledger.quote_purchase(jsonb,jsonb,jsonb,uuid,bytea,text,text,text,bigint,timestamptz),
    meton_ledger.commit_purchase(jsonb,jsonb,jsonb,uuid,bytea,uuid,text,text,text,bigint,timestamptz),
    meton_ledger.claim_purchase_dispatch(jsonb,jsonb,jsonb,uuid,bytea,uuid,timestamptz),
    meton_ledger.observe_purchase_dispatch(jsonb,uuid,uuid,text,text,timestamptz),
    meton_ledger.read_original_purchase(jsonb,uuid,timestamptz) FROM PUBLIC;
