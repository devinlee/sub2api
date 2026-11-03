-- S1 仅证明从受控建号事务起一直处于禁资金模式的对象。已有用户和旧创建不回填资格。
CREATE TABLE meton_s1_funds_births (
    remote_user bigint PRIMARY KEY REFERENCES users(id) ON DELETE RESTRICT,
    born_xid xid8 NOT NULL, operation uuid UNIQUE REFERENCES meton_managed_creations(operation) ON DELETE RESTRICT,
    marker uuid NOT NULL UNIQUE DEFAULT gen_random_uuid()
);
CREATE FUNCTION meton_s1_new_birth() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF NEW.password_hash='!meton-managed' AND NEW.restrict_public_groups AND NEW.role='user' AND
       NEW.email ~ '^meton-[0-9a-f-]{36}@managed\.invalid$' THEN
        IF NEW.balance<>0 OR NEW.frozen_balance<>0 OR NEW.total_recharged<>0 THEN
            RAISE EXCEPTION 'managed funds disabled' USING ERRCODE='23514';
        END IF;
        INSERT INTO public.meton_s1_funds_births(remote_user,born_xid) VALUES(NEW.id,pg_current_xact_id());
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_s1_new_birth AFTER INSERT ON users FOR EACH ROW EXECUTE FUNCTION meton_s1_new_birth();
CREATE FUNCTION meton_s1_bind_birth() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    UPDATE public.meton_s1_funds_births SET operation=NEW.operation WHERE remote_user=NEW.remote_user
        AND born_xid=pg_current_xact_id() AND operation IS NULL;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_s1_bind_birth AFTER INSERT ON meton_managed_creations FOR EACH ROW EXECUTE FUNCTION meton_s1_bind_birth();
-- 出生记录只允许建号触发器在原事务中创建并绑定一次。后来补写或删除不能制造“从未有资金”的证据。
CREATE FUNCTION meton_s1_keep_birth() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF TG_OP='INSERT' AND pg_trigger_depth()>1 AND NEW.born_xid=pg_current_xact_id() AND NEW.operation IS NULL THEN RETURN NEW; END IF;
    IF TG_OP='UPDATE' AND pg_trigger_depth()>1 AND OLD.operation IS NULL AND NEW.operation IS NOT NULL AND OLD.born_xid=pg_current_xact_id()
       AND ROW(NEW.remote_user,NEW.born_xid,NEW.marker)=ROW(OLD.remote_user,OLD.born_xid,OLD.marker) THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'immutable funds origin' USING ERRCODE='23514';
END $$;
CREATE TRIGGER meton_s1_keep_birth BEFORE INSERT OR UPDATE OR DELETE ON meton_s1_funds_births FOR EACH ROW EXECUTE FUNCTION meton_s1_keep_birth();

-- 补丁只禁止保护范围内的资金变化。旧用户及旧订单仍归原账本，恢复或退款不能被此门禁抹掉。
CREATE FUNCTION meton_s1_deny_balance() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF ROW(NEW.balance,NEW.frozen_balance,NEW.total_recharged) IS DISTINCT FROM ROW(OLD.balance,OLD.frozen_balance,OLD.total_recharged)
       AND EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=OLD.id) THEN
        RAISE EXCEPTION 'managed funds disabled' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_s1_no_native_balance BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_balance();
CREATE FUNCTION meton_s1_deny_fund_row() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE field text; uid bigint;
BEGIN
    FOREACH field IN ARRAY TG_ARGV LOOP
        uid:=(to_jsonb(NEW)->>field)::bigint;
        IF field='api_key_id' THEN SELECT user_id INTO uid FROM public.api_keys WHERE id=uid; END IF;
        IF EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=uid) THEN
            RAISE EXCEPTION 'managed funds disabled' USING ERRCODE='23514';
        END IF;
    END LOOP;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_s1_no_order BEFORE INSERT OR UPDATE ON payment_orders FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('user_id');
CREATE TRIGGER meton_s1_no_redeem BEFORE INSERT OR UPDATE ON redeem_codes FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('used_by');
CREATE TRIGGER meton_s1_no_promo BEFORE INSERT OR UPDATE ON promo_code_usages FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('user_id');
CREATE TRIGGER meton_s1_no_subscription BEFORE INSERT OR UPDATE ON user_subscriptions FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('user_id');
CREATE TRIGGER meton_s1_no_usage BEFORE INSERT OR UPDATE ON usage_logs FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('user_id','api_key_id');
CREATE TRIGGER meton_s1_no_dedup BEFORE INSERT OR UPDATE ON usage_billing_dedup FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('api_key_id');
CREATE TRIGGER meton_s1_no_archived_dedup BEFORE INSERT OR UPDATE ON usage_billing_dedup_archive FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('api_key_id');
CREATE TRIGGER meton_s1_no_affiliate BEFORE INSERT OR UPDATE ON user_affiliates FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('user_id','inviter_id');
CREATE TRIGGER meton_s1_no_affiliate_ledger BEFORE INSERT OR UPDATE ON user_affiliate_ledger FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('user_id','source_user_id');
CREATE TRIGGER meton_s1_no_group BEFORE INSERT OR UPDATE ON user_allowed_groups FOR EACH ROW EXECUTE FUNCTION meton_s1_deny_fund_row('user_id');
-- S1 的受控签发先写 api_keys，再在同一事务记录原托管绑定。延后到事务末尾核对，禁止原生发钥匙或改归属。
CREATE FUNCTION meton_s1_key_owner() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
    IF TG_OP='UPDATE' AND OLD.user_id<>NEW.user_id AND EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=OLD.user_id) THEN
        RAISE EXCEPTION 'managed key owner changed' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT FROM public.meton_s1_funds_births WHERE remote_user=NEW.user_id) AND NOT EXISTS
        (SELECT FROM public.meton_managed_keys k JOIN public.meton_managed_creations m ON m.source_marker=k.source_marker
         WHERE k.remote_key=NEW.id AND m.remote_user=NEW.user_id) THEN
        RAISE EXCEPTION 'managed native key disabled' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE CONSTRAINT TRIGGER meton_s1_only_managed_key AFTER INSERT OR UPDATE OF user_id ON api_keys
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION meton_s1_key_owner();

-- 每次从同一 SQL 语句的快照核对来源、真实用户、写代次和全部原生资金入口。查无不是零。
CREATE FUNCTION meton_s1_funds_state(p_env text,p_source text,p_epoch bigint,p_original uuid)
RETURNS TABLE(meton_user uuid,account uuid,dispatch uuid,remote_user bigint,source_marker uuid,birth_marker uuid,state text,observed_at timestamptz)
LANGUAGE sql STABLE SET search_path=pg_catalog,public AS $$
 SELECT m.meton_user,m.account,m.dispatch,u.id,m.source_marker,b.marker,
    CASE WHEN u.balance<>0 OR u.frozen_balance<>0 OR u.total_recharged<>0
        OR EXISTS(SELECT FROM public.payment_orders o WHERE o.user_id=u.id)
        OR EXISTS(SELECT FROM public.redeem_codes r WHERE r.used_by=u.id)
        OR EXISTS(SELECT FROM public.promo_code_usages p WHERE p.user_id=u.id)
        OR EXISTS(SELECT FROM public.user_subscriptions s WHERE s.user_id=u.id)
        OR EXISTS(SELECT FROM public.usage_logs l WHERE l.user_id=u.id)
        OR EXISTS(SELECT FROM public.user_affiliates a WHERE a.user_id=u.id OR a.inviter_id=u.id)
        OR EXISTS(SELECT FROM public.user_affiliate_ledger l WHERE l.user_id=u.id OR l.source_user_id=u.id)
        OR EXISTS(SELECT FROM public.api_keys k WHERE k.user_id=u.id AND
            (EXISTS(SELECT FROM public.usage_billing_dedup d WHERE d.api_key_id=k.id) OR
             EXISTS(SELECT FROM public.usage_billing_dedup_archive d WHERE d.api_key_id=k.id)))
        THEN 'funds_or_activity'
        WHEN b.marker IS NULL OR u.email<>'meton-'||m.account::text||'@managed.invalid' OR u.password_hash<>'!meton-managed'
            OR NOT u.restrict_public_groups OR u.status<>'active' OR u.deleted_at IS NOT NULL OR u.role<>'user'
            OR EXISTS(SELECT FROM public.api_keys k WHERE k.user_id=u.id AND NOT EXISTS
                (SELECT FROM public.meton_managed_keys a WHERE a.remote_key=k.id AND a.source_marker=m.source_marker))
            OR EXISTS(SELECT FROM public.user_allowed_groups g WHERE g.user_id=u.id)
            -- 原生幂等表只存请求指纹，没有可核验的受益账户。未决操作不能归给某人，也不能用来证明安全关闭。
            OR EXISTS(SELECT FROM public.idempotency_records r WHERE r.status<>'succeeded')
            THEN 'history_unverified' ELSE 'controlled_empty' END,statement_timestamp()
 FROM public.meton_managed_creations m JOIN public.meton_managed_fence f ON f.singleton AND f.enabled AND
       f.environment=m.environment AND f.source=m.source AND f.epoch=m.epoch
 JOIN public.users u ON u.id=m.remote_user LEFT JOIN public.meton_s1_funds_births b ON b.remote_user=u.id AND b.operation=m.operation
 WHERE m.environment=p_env AND m.source=p_source AND m.epoch=p_epoch AND m.operation=p_original
   AND NOT pg_is_in_recovery() AND current_setting('session_replication_role')='origin'
   AND NOT EXISTS (
       SELECT FROM (VALUES ('users','meton_s1_new_birth'),('meton_managed_creations','meton_s1_bind_birth'),('meton_s1_funds_births','meton_s1_keep_birth'),('users','meton_s1_no_native_balance'),
           ('payment_orders','meton_s1_no_order'),('redeem_codes','meton_s1_no_redeem'),('promo_code_usages','meton_s1_no_promo'),
           ('user_subscriptions','meton_s1_no_subscription'),('usage_logs','meton_s1_no_usage'),('usage_billing_dedup','meton_s1_no_dedup'),
           ('usage_billing_dedup_archive','meton_s1_no_archived_dedup'),('user_affiliates','meton_s1_no_affiliate'),
           ('user_affiliate_ledger','meton_s1_no_affiliate_ledger'),('user_allowed_groups','meton_s1_no_group'),('api_keys','meton_s1_only_managed_key')) g(tbl,trg)
       WHERE NOT EXISTS (SELECT FROM pg_trigger t WHERE t.tgrelid=to_regclass('public.'||g.tbl) AND t.tgname=g.trg AND t.tgenabled='O'));
$$;
