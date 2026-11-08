-- 账户额度仍归来源账本；这里只复用原生并发设置约束持久未决，不建立另一份余额或 Key 计数。
CREATE FUNCTION meton_ledger.enforce_text_account_limit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE remote_id bigint; maximum integer; pending bigint;
BEGIN
    -- 等待账户锁后必须看到前一持有者的新请求；固定旧快照不能据此计算剩余名额。
    IF current_setting('transaction_isolation')<>'read committed' THEN
        RAISE EXCEPTION 'current committed account admission required' USING ERRCODE='55000';
    END IF;
    -- 与原受理保持相同锁序；切代或恢复维护期间不能借新触发器重新取得发送资格。
    PERFORM 1 FROM public.meton_managed_fence
        WHERE singleton AND enabled AND environment=NEW.environment AND source=NEW.source AND epoch=NEW.epoch_at_accept FOR SHARE;
    IF NOT FOUND OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' THEN
        RAISE EXCEPTION 'account admission source unavailable' USING ERRCODE='55000';
    END IF;
    SELECT u.id,u.concurrency INTO remote_id,maximum
        FROM public.meton_managed_creations m JOIN public.users u ON u.id=m.remote_user
        WHERE m.source_marker=NEW.source_marker AND m.environment=NEW.environment AND m.source=NEW.source
            AND m.epoch=NEW.epoch_at_accept FOR UPDATE OF u;
    IF NOT FOUND OR maximum IS NULL OR maximum<1 THEN
        RAISE EXCEPTION 'account admission limit unavailable' USING ERRCODE='55000';
    END IF;
    -- 不按 Key、用途或副本分桶。只有原条件取消／费用结清可归还名额，断线和未知继续保留。
    SELECT count(*) INTO pending FROM meton_ledger.text_requests r
        JOIN public.meton_managed_creations origin ON origin.source_marker=r.source_marker
        WHERE origin.remote_user=remote_id
          AND NOT EXISTS(SELECT FROM meton_ledger.text_send_decisions d WHERE d.request_id=r.request_id AND d.state='cancelled_unsent')
          AND NOT EXISTS(SELECT FROM meton_ledger.text_fee_endings f WHERE f.request_id=r.request_id);
    IF pending>=maximum THEN
        RAISE EXCEPTION 'account pending model limit reached' USING ERRCODE='P5302';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.enforce_text_account_limit() FROM PUBLIC;
CREATE TRIGGER enforce_text_account_limit BEFORE INSERT ON meton_ledger.text_requests
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.enforce_text_account_limit();
