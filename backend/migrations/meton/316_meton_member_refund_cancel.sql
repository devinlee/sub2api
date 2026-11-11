-- 会员入口只接受原确认号、退款号和版本。原外部证明由受限托管服务从固定的独立实例取得。
ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel','lifecycle',
        'refund_quote','refund_quote_status','refund_confirm','refund_status','refund_cancel'));
DO $extend$
DECLARE member_def text:=pg_get_functiondef('meton_ledger.apply_member_refund(text,jsonb,jsonb,jsonb,uuid,timestamptz)'::regprocedure);
    native_def text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    actions constant text:='''refund_quote'',''refund_quote_status'',''refund_confirm'',''refund_status''';
    point constant text:='WHEN ''refund_quote'' THEN';
BEGIN
    IF cardinality(string_to_array(native_def,actions))<>3 OR cardinality(string_to_array(member_def,point))<>2 THEN
        RAISE EXCEPTION 'original refund HTTP configuration changed'; END IF;
    EXECUTE replace(native_def,actions,actions||',''refund_cancel''');
    EXECUTE replace(member_def,point,$cancel$WHEN 'refund_cancel' THEN
        choice:=req->'refundCancellation';
        result:=meton_ledger.prepare_refund_cancel(owner,person,operation,(choice->>'refund')::uuid,(choice->>'version')::bigint,deadline);
    $cancel$||point);
END $extend$;
CREATE FUNCTION meton_ledger.http_checkout_refund_cancel(text,text,bigint,timestamptz,bigint,text) RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT meton_ledger.apply_checkout_http('refund_cancel',$1,$2,$3,$4,$5,$6) $$;

CREATE FUNCTION meton_ledger.http_finish_refund_cancel(wire text,key_id text,creator bigint,revision timestamptz,until_ms bigint,witness text,proof jsonb)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE validated jsonb; request jsonb:=wire::jsonb; o jsonb:=request->'origin'; actor jsonb:=request->'desktop';
    original uuid:=(request->>'intent')::uuid; ref uuid:=(request#>>'{refundCancellation,refund}')::uuid;
    until_at timestamptz:=least((request->>'validUntil')::timestamptz,to_timestamp(until_ms::numeric/1000)); phase text; decision jsonb;
BEGIN
    -- 再确认原生角色、签名正文、精确会话及截止，用户不能自行提交归还证明。
    validated:=meton_ledger.apply_checkout_http('refund_cancel',wire,key_id,creator,revision,until_ms,witness)::jsonb;
    IF validated?'current' THEN RETURN (validated->'current')::text; END IF;
    o:=(o-'sourceMarker'-'remoteUser')||jsonb_build_object('source_marker',o->'sourceMarker','remote_user',o->'remoteUser',
        'source_system',meton_ledger.notification_system_id());
    actor:=(actor-'securityVersion'-'recoveryVersion')||jsonb_build_object('security_version',actor->'securityVersion','recovery_version',actor->'recoveryVersion');
    phase:=meton_ledger.apply_refund_gate_receipt(o,original,ref,proof);
    decision:=meton_ledger.read_original_refund_decision(o,actor,original,until_at);
    IF phase='review' OR phase='held' OR decision->>'phase' IS DISTINCT FROM phase THEN
        RAISE EXCEPTION 'original refund remains under review' USING ERRCODE='55000'; END IF;
    RETURN decision::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.http_checkout_refund_cancel(text,text,bigint,timestamptz,bigint,text),
    meton_ledger.http_finish_refund_cancel(text,text,bigint,timestamptz,bigint,text,jsonb) FROM PUBLIC;
