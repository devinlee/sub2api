-- 当前写权限与原业务身份分开。内部帮助函数不向运行身份授予直接执行权。
CREATE FUNCTION meton_ledger.require_original_fee_epoch(h meton_ledger.text_hold_receipt,p_epoch bigint)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a public.meton_managed_creations%ROWTYPE; proof public.meton_recovery_successions%ROWTYPE; expected bigint;
BEGIN
    IF h.epoch_at_accept IS NULL OR p_epoch IS NULL OR h.epoch_at_accept>p_epoch THEN
        RAISE EXCEPTION 'original fee epoch unconfirmed' USING ERRCODE='55000'; END IF;
    IF h.epoch_at_accept=p_epoch THEN RETURN; END IF;
    -- 原恢复凭证只能由离线所有者写。可伪造其内容的运行身份不能据此获得历史资金权。
    IF has_any_column_privilege(session_user,'public.meton_recovery_successions','INSERT,UPDATE') OR
       has_table_privilege(session_user,'public.meton_recovery_successions','DELETE,TRUNCATE,TRIGGER') THEN
        RAISE EXCEPTION 'recovery writer cannot settle fees' USING ERRCODE='42501'; END IF;
    SELECT * INTO a FROM public.meton_managed_creations WHERE source_marker=h.source_marker AND epoch=p_epoch AND
        (environment,source,meton_user,account)=(h.environment,h.source,h.meton_user,h.account) FOR SHARE;
    IF NOT FOUND OR NOT EXISTS(SELECT FROM meton_ledger.text_requests r
        JOIN public.meton_managed_keys k ON k.operation=r.origin_key AND k.source_marker=r.source_marker
        JOIN public.api_keys material ON material.id=k.remote_key AND material.user_id=a.remote_user AND material.status='inactive'
        JOIN public.meton_managed_key_retirements retired ON retired.remote_key=k.remote_key AND retired.operation=k.operation AND retired.key_marker=k.key_marker
        JOIN public.meton_managed_session_closures closed ON closed.source_marker=k.source_marker AND closed.session_id=k.session_id
        WHERE r.request_id=h.request_id AND r.source_marker=h.source_marker AND r.epoch_at_accept=h.epoch_at_accept AND
            k.claim->'origin'->>'epoch'=h.epoch_at_accept::text AND material.created_at=k.created_at AND material.expires_at=k.expires_at AND
            encode(sha256(convert_to(material.key,'UTF8')),'hex')=k.material_sha256) THEN
        RAISE EXCEPTION 'retired original fee key required' USING ERRCODE='55000'; END IF;
    expected:=h.epoch_at_accept;
    -- 代次来自独立序列，可以跨数值；每一段原前驱必须相接，不能只比较大小。
    WHILE expected<p_epoch LOOP
        SELECT * INTO proof FROM public.meton_recovery_successions WHERE source_marker=h.source_marker AND previous_epoch=expected FOR SHARE;
        IF NOT FOUND OR proof.next_epoch>p_epoch OR proof.next_epoch<=expected OR
           (proof.environment,proof.source,proof.meton_user,proof.account,proof.operation,proof.dispatch,proof.remote_user,proof.source_marker)
              IS DISTINCT FROM (a.environment,a.source,a.meton_user,a.account,a.operation,a.dispatch,a.remote_user,a.source_marker) THEN
            RAISE EXCEPTION 'continuous original fee recovery required' USING ERRCODE='55000'; END IF;
        expected:=proof.next_epoch;
    END LOOP;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.require_original_fee_epoch(meton_ledger.text_hold_receipt,bigint) FROM PUBLIC;

CREATE OR REPLACE FUNCTION meton_ledger.lock_dispatched_fee(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,p_request uuid)
RETURNS meton_ledger.text_hold_receipt LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; remote_id bigint; native numeric; total numeric;
BEGIN
    remote_id:=meton_ledger.lock_text_owner(p_env,p_source,p_epoch,p_user,p_account,p_marker);
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request OR h.state<>'dispatch_claimed' THEN
        RAISE EXCEPTION 'dispatched original required' USING ERRCODE='55000';
    END IF;
    PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
    SELECT balance INTO native FROM public.users WHERE id=remote_id AND frozen_balance=0;
    SELECT sum(l.remaining) INTO total FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event WHERE e.source_marker=p_marker;
    IF native IS NULL OR native IS DISTINCT FROM total OR NOT EXISTS (SELECT FROM meton_ledger.accounts a JOIN meton_ledger.events e
        ON e.source_marker=a.source_marker AND e.sequence=a.last_sequence WHERE a.source_marker=p_marker AND a.unit=h.unit AND e.balance_after=native) THEN
        RAISE EXCEPTION 'source journal requires reconciliation' USING ERRCODE='23514';
    END IF;
    RETURN h;
END $$;

CREATE OR REPLACE FUNCTION meton_ledger.observe_text_fee(p_env text,p_source text,p_epoch bigint,p_user uuid,p_account uuid,p_marker uuid,p_caller text,p_operation uuid,
        p_request uuid,p_item uuid,p_event uuid,p_revision integer,p_price text,p_unit text,p_amount text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE h meton_ledger.text_hold_receipt; receipt jsonb;
BEGIN
    PERFORM meton_ledger.lock_text_owner(p_env,p_source,p_epoch,p_user,p_account,p_marker);
    SELECT * INTO h FROM meton_ledger.find_text_hold(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation);
    IF NOT FOUND OR h.request_id IS DISTINCT FROM p_request OR h.state<>'dispatch_claimed' THEN
        RAISE EXCEPTION 'original dispatched request unconfirmed' USING ERRCODE='55000';
    END IF;
    PERFORM meton_ledger.require_original_fee_epoch(h,p_epoch);
    IF num_nulls(p_item,p_event,p_revision,p_price,p_unit,p_amount)>0 OR '00000000-0000-0000-0000-000000000000'::uuid IN (p_item,p_event)
        OR p_revision<1 OR p_amount !~ '^(0|[1-9][0-9]{0,11})[.][0-9]{8}$' THEN
        RAISE EXCEPTION 'invalid observed fee' USING ERRCODE='22023';
    END IF;
    IF (p_price,p_unit) IS DISTINCT FROM (h.price_version,h.unit) THEN RAISE EXCEPTION 'not original fee price or unit' USING ERRCODE='23505'; END IF;
    INSERT INTO meton_ledger.text_fee_reports(event_id,request_id,item_id,revision,state,amount)
        VALUES(p_event,p_request,p_item,p_revision,'observed',p_amount::numeric)
        ON CONFLICT DO NOTHING;
    receipt:=meton_ledger.find_text_fee(p_env,p_source,p_epoch,p_user,p_account,p_marker,p_caller,p_operation,p_request,p_item,p_event);
    IF receipt IS NULL OR receipt->'item'->>'state'<>'observed' OR receipt->'item'->>'amount'<>p_amount
        OR (receipt->'item'->>'revision')::integer<>p_revision THEN
        RAISE EXCEPTION 'original fee event or revision conflict' USING ERRCODE='23505';
    END IF;
    RETURN receipt;
END $$;
