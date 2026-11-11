-- 退款走原托管角色认证、密钥代次和独立用途。报价窗口由来源发布，客户端不能指定有效期或来源库。
CREATE TABLE meton_ledger.cash_refund_http_terms(
    environment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),source_system text NOT NULL,
    quote_seconds integer NOT NULL CHECK(quote_seconds>0),PRIMARY KEY(environment,source,epoch)
);
CREATE TRIGGER immutable_refund_http_terms BEFORE UPDATE OR DELETE ON meton_ledger.cash_refund_http_terms
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.cash_refund_http_terms ENABLE ALWAYS TRIGGER immutable_refund_http_terms;
REVOKE ALL ON meton_ledger.cash_refund_http_terms FROM PUBLIC;

CREATE FUNCTION meton_ledger.apply_member_refund(action text,req jsonb,orig jsonb,person jsonb,operation uuid,deadline timestamptz)
RETURNS text LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE terms meton_ledger.cash_refund_http_terms; owner jsonb; choice jsonb; result jsonb;
BEGIN
    SELECT * INTO terms FROM meton_ledger.cash_refund_http_terms t WHERE (t.environment,t.source,t.epoch)=
        (orig->>'environment',orig->>'source',(orig->>'epoch')::bigint);
    IF NOT FOUND OR terms.source_system<>meton_ledger.notification_system_id() THEN RAISE EXCEPTION 'refund source unavailable' USING ERRCODE='55000'; END IF;
    owner:=orig||jsonb_build_object('source_system',terms.source_system);
    PERFORM meton_ledger.require_refund_actor(owner,person,deadline);
    IF req ?| ARRAY['browser','webProof','challenge','challengeHash','wantCode','selection','returnTarget','closeVersion'] THEN
        RAISE EXCEPTION 'refund requires member session' USING ERRCODE='42501'; END IF;
    CASE action
    WHEN 'refund_quote' THEN
        choice:=req->'refundSelection';
        PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((orig->>'source_marker')::uuid));
        PERFORM pg_advisory_xact_lock_shared(hashtextextended(((orig->>'source_marker')::uuid)::text||':'||((person->>'session')::uuid)::text,0));
        PERFORM meton_ledger.require_refund_actor(owner,person,deadline);
        result:=meton_ledger.quote_original_refund(owner,operation,(choice->>'order')::bigint,(choice->>'part')::uuid,(choice->>'cutoff')::uuid,
            choice->>'basis',choice->>'units',(choice->>'fen')::bigint,clock_timestamp()+make_interval(secs=>terms.quote_seconds));
    WHEN 'refund_quote_status' THEN result:=meton_ledger.read_original_refund_quote(owner,operation);
    WHEN 'refund_confirm' THEN
        choice:=req->'refundConfirmation';
        result:=meton_ledger.confirm_original_refund(owner,person,operation,(choice->>'quote')::uuid,choice->>'basisVersion',(choice->>'fen')::bigint,deadline);
    WHEN 'refund_status' THEN result:=meton_ledger.read_original_refund_decision(owner,person,operation,deadline);
    ELSE RAISE EXCEPTION 'unknown refund action' USING ERRCODE='42501';
    END CASE;
    -- 发生未知提交后，按原号取回的报价还要与本次选择逐项比对，不能用同价的其他份额冒充本次结果。
    IF action IN ('refund_quote','refund_quote_status') AND result IS NOT NULL THEN
        SELECT result||jsonb_build_object('selection',jsonb_strip_nulls(jsonb_build_object('order',q.request->>'order',
            'part',q.request->>'part','cutoff',q.request->>'cutoff','basis',q.request->>'basis','units',q.request->>'units','fen',q.request->>'fen')))
            INTO STRICT result FROM meton_ledger.cash_refund_quotes q WHERE (q.quote_id,q.source_marker)=(operation,(owner->>'source_marker')::uuid);
    END IF;
    PERFORM meton_ledger.require_refund_actor(owner,person,deadline);
    RETURN result::text;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.apply_member_refund(text,jsonb,jsonb,jsonb,uuid,timestamptz) FROM PUBLIC;

ALTER TABLE meton_ledger.checkout_http_keys DROP CONSTRAINT checkout_http_keys_action_check,
    ADD CHECK(action IN ('issue','redeem','status','quote','confirm','order','present','cancel','lifecycle',
        'refund_quote','refund_quote_status','refund_confirm','refund_status'));
DO $refund_http$
DECLARE original text:=pg_get_functiondef('meton_ledger.apply_checkout_http(text,text,text,bigint,timestamptz,bigint,text)'::regprocedure);
    actions constant text:='''issue'',''redeem'',''status'',''quote'',''confirm'',''order'',''present'',''cancel'',''lifecycle''';
    reads constant text:='(''status'',''order'')'; branch constant text:='WHEN ''lifecycle'' THEN'; name text;
BEGIN
    IF cardinality(string_to_array(original,actions))<>2 OR cardinality(string_to_array(original,reads))<>3
        OR cardinality(string_to_array(original,branch))<>2 THEN RAISE EXCEPTION 'original cash HTTP authority changed'; END IF;
    original:=replace(original,actions,actions||',''refund_quote'',''refund_quote_status'',''refund_confirm'',''refund_status''');
    original:=replace(original,reads,'(''status'',''order'',''refund_quote_status'',''refund_status'')');
    EXECUTE replace(original,branch,$apply$WHEN 'refund_quote','refund_quote_status','refund_confirm','refund_status' THEN
        result:=meton_ledger.apply_member_refund(p_action,q,orig,desk,sid,deadline);
        $apply$||branch);
    FOREACH name IN ARRAY ARRAY['refund_quote','refund_quote_status','refund_confirm','refund_status'] LOOP
        EXECUTE format('CREATE FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS %L',
            'http_checkout_'||name,format('SELECT meton_ledger.apply_checkout_http(%L,$1,$2,$3,$4,$5,$6)',name));
        EXECUTE format('REVOKE ALL ON FUNCTION meton_ledger.%I(text,text,bigint,timestamptz,bigint,text) FROM PUBLIC','http_checkout_'||name);
    END LOOP;
END $refund_http$;
