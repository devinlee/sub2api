-- 原独立受理用途可交接最终事实，只读用途查询售后；不新增会员会话入口或现金执行器。
ALTER FUNCTION meton_ledger.checkout_cash_closure_refunds(text,jsonb,jsonb,uuid) RENAME TO checkout_cash_closure_refunds_v345;
CREATE FUNCTION meton_ledger.checkout_cash_closure_refunds(action text,q jsonb,orig jsonb,closure uuid) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE owner jsonb:=orig||jsonb_build_object('source_system',meton_ledger.notification_system_id());value jsonb;
BEGIN
    IF NOT q ? 'aftercare' THEN RETURN meton_ledger.checkout_cash_closure_refunds_v345(action,q,orig,closure); END IF;
    IF q->'aftercare' IS DISTINCT FROM 'true'::jsonb OR
        q-ARRAY['version','origin','intent','registration','sourceSystem','scopeHash','decision','aftercare','validUntil']<>'{}'::jsonb OR
        q->>'sourceSystem' IS DISTINCT FROM owner->>'source_system' OR
        (q->>'registration'~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' AND q->>'scopeHash'~'^[0-9a-f]{64}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'original restricted aftercare input required' USING ERRCODE='22023'; END IF;
    IF action='closure_refund_admit' THEN
        value:=meton_ledger.record_cash_closure_final(owner,closure,(q->>'registration')::uuid,q->>'scopeHash',q->'decision',(q->>'validUntil')::timestamptz);
    ELSIF action='closure_refunds' AND NOT q ? 'decision' THEN
        value:=meton_ledger.read_cash_closure_aftercare(owner,closure,(q->>'registration')::uuid,q->>'scopeHash');
    ELSE RAISE EXCEPTION 'separate final handoff and read purposes required' USING ERRCODE='42501'; END IF;
    RETURN value::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.checkout_cash_closure_refunds(text,jsonb,jsonb,uuid) FROM PUBLIC;
