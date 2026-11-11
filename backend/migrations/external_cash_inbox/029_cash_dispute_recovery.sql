-- 来源恢复或当前权威轮换只接续原案，不继承旧审核资格，也不改现金和来源份额。
CREATE OR REPLACE FUNCTION meton_inbox.bind_cash_dispute(route jsonb,proof jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);f jsonb:=proof->'facts';e jsonb:=f->'origin';
    s jsonb;c meton_inbox.cash_dispute_cases;b meton_inbox.refund_wire_bindings;key bytea;x jsonb;
BEGIN
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    IF proof->>'state' IS DISTINCT FROM 'ready' OR f->>'format' IS DISTINCT FROM '1' OR f->'scope' IS DISTINCT FROM s OR
        e->'scope' IS DISTINCT FROM s||jsonb_build_object('channel',route->>'channel','cashEnvironment',route->>'cashEnvironment','merchant',route->>'merchant','app',route->>'app') OR
        ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '30 seconds') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.cash.dispute.origin.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'current dispute origin required' USING ERRCODE='42501'; END IF;
    key:=meton_inbox.lock_original_cash(route,e#>>'{cash,order}',e#>>'{cash,transaction}');
    SELECT * INTO c FROM meton_inbox.cash_dispute_cases WHERE original=key FOR UPDATE;
    IF c.id IS NULL THEN
        b.envelope:=e;b.channel:=route->>'channel';b.cash_environment:=route->>'cashEnvironment';b.merchant:=route->>'merchant';
        x:=meton_inbox.original_cash_return_exposure(b);
        IF x IS NULL THEN RETURN jsonb_build_object('state','not_required'); END IF;
        IF (x->>'pendingCommit')::boolean THEN RETURN jsonb_build_object('state','recorded'); END IF;
        x:=x-'pendingCommit';
        INSERT INTO meton_inbox.cash_dispute_cases(original,origin,epoch,key_ref,revision,cash,cash_hash,state)
            VALUES(key,e,a.epoch,a.key_ref,1,x,sha256(convert_to(x::text,'UTF8')),'pending_review') RETURNING * INTO c;
        INSERT INTO meton_inbox.cash_dispute_history VALUES(c.id,c.revision,meton_inbox.cash_dispute_value(c),a.epoch,session_user);
    ELSE
        IF jsonb_build_array(c.origin#>'{owner,user}',c.origin#>'{owner,account}',c.origin#>'{owner,source_marker}',c.origin->'target') IS DISTINCT FROM
            jsonb_build_array(e#>'{owner,user}',e#>'{owner,account}',e#>'{owner,source_marker}',e->'target') THEN
            RAISE EXCEPTION 'dispute original identity changed' USING ERRCODE='42501'; END IF;
        -- 换代、换签章或换数据库权威后，原领取与结论只保留为历史；当前审核必须重新领取。
        -- 原案件和已提交材料不换编号，重投同一绑定也不能反复撤销当前审核或增加版本。
        IF (c.epoch,c.key_ref,c.origin#>>'{scope,sourceSystem}',c.origin#>>'{scope,inboxSystem}') IS DISTINCT FROM
            (a.epoch,a.key_ref,a.source_system,meton_inbox.system_id()) THEN
            UPDATE meton_inbox.cash_dispute_cases SET origin=e,epoch=a.epoch,key_ref=a.key_ref,revision=revision+1,
                state='pending_review',assigned_to=NULL,assigned_epoch=NULL,finding=NULL,reference=NULL,
                updated_at=clock_timestamp(),recorded_xid=pg_current_xact_id() WHERE id=c.id RETURNING * INTO c;
            INSERT INTO meton_inbox.cash_dispute_history VALUES(c.id,c.revision,meton_inbox.cash_dispute_value(c),a.epoch,session_user);
        ELSE
            UPDATE meton_inbox.cash_dispute_cases SET origin=e WHERE id=c.id;
        END IF;
        c:=meton_inbox.refresh_cash_dispute(c.id);
    END IF;
    RETURN jsonb_build_object('state',CASE WHEN c.id IS NULL OR c.recorded_xid=pg_current_xact_id() THEN 'recorded' ELSE 'bound' END,'id',c.id);
END $$;
