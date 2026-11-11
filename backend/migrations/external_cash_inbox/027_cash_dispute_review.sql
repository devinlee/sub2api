-- 原付款只有一个争议事项；负责人、核对材料和结论属于进度，不允许据此写现金或来源余额。
CREATE TABLE meton_inbox.cash_dispute_cases(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),original bytea NOT NULL UNIQUE CHECK(octet_length(original)=32),origin jsonb NOT NULL,
    epoch bigint NOT NULL,key_ref uuid NOT NULL,revision bigint NOT NULL CHECK(revision>0),cash jsonb NOT NULL,cash_hash bytea NOT NULL,
    state text NOT NULL CHECK(state IN ('pending_review','reviewing','awaiting_material','reviewed_restricted')),
    assigned_to name,assigned_epoch bigint,finding text,reference text,updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE TABLE meton_inbox.cash_dispute_history(
    dispute uuid NOT NULL REFERENCES meton_inbox.cash_dispute_cases,revision bigint NOT NULL,value jsonb NOT NULL,
    epoch bigint NOT NULL,actor name NOT NULL,PRIMARY KEY(dispute,revision)
);
CREATE TABLE meton_inbox.cash_dispute_actions(
    dispute uuid NOT NULL REFERENCES meton_inbox.cash_dispute_cases,operation uuid NOT NULL,facts jsonb NOT NULL,revision bigint NOT NULL,
    reviewer name NOT NULL,key_ref text NOT NULL,sealed bytea NOT NULL,PRIMARY KEY(dispute,operation),
    FOREIGN KEY(dispute,revision) REFERENCES meton_inbox.cash_dispute_history
);
DO $protect$ DECLARE n text;BEGIN
    FOREACH n IN ARRAY ARRAY['cash_dispute_history','cash_dispute_actions'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
    END LOOP;
END $protect$;
REVOKE ALL ON meton_inbox.cash_dispute_cases,meton_inbox.cash_dispute_history,meton_inbox.cash_dispute_actions FROM PUBLIC;

/** 现金和审核动作共用原工作队列；只唤醒相关原付款，不制造新的现金请求。 */
CREATE FUNCTION meton_inbox.wake_original_cash_work(originals bytea[]) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE item record;
BEGIN
    FOR item IN SELECT b.refund FROM meton_inbox.refund_wire_bindings b WHERE meton_inbox.cash_original_identity(b.envelope)=ANY(originals) ORDER BY b.refund
    LOOP PERFORM meton_inbox.wake_refund_settlement(item.refund); END LOOP;
    UPDATE meton_inbox.purchase_delivery d SET token=gen_random_uuid(),state='retry',available_at=clock_timestamp(),reason='new_cash_fact'
        WHERE d.review_epoch IS NOT NULL AND EXISTS(SELECT FROM meton_inbox.external_cash_returns x WHERE
            (x.receipt,x.digest)=(d.receipt,d.digest) AND x.original=ANY(originals));
END $$;
DO $reuse$
DECLARE body text:=pg_get_functiondef('meton_inbox.wake_combined_cash_reviews()'::regprocedure);first_at integer;last_at integer;
BEGIN
    first_at:=strpos(body,'    FOR item IN SELECT b.refund');last_at:=strpos(body,'    RETURN NEW;');
    IF first_at=0 OR last_at<=first_at THEN RAISE EXCEPTION 'combined cash wakeup changed'; END IF;
    EXECUTE substr(body,1,first_at-1)||'    PERFORM meton_inbox.wake_original_cash_work(originals);'||chr(10)||substr(body,last_at);
END $reuse$;

/** 投影只有必要的原归属、核对进度和现金事实，不含材料正文、发送秘密或扣款命令。 */
CREATE FUNCTION meton_inbox.cash_dispute_value(c meton_inbox.cash_dispute_cases) RETURNS jsonb
LANGUAGE sql SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
    SELECT jsonb_build_object('format',1,'id',c.id,'original',encode(c.original,'hex'),'revision',c.revision,
        'owner',jsonb_build_array(c.origin#>'{owner,user}',c.origin#>'{owner,account}',c.origin#>'{owner,source_marker}',c.origin#>'{target,nativeOrder}',c.origin#>'{target,payment}',c.origin#>'{target,cutoff}'),
        'state',c.state,'assignedTo',c.assigned_to,'finding',c.finding,'reference',c.reference,'updatedAt',c.updated_at,
        'cashExposure',c.cash,'cashHash',encode(c.cash_hash,'hex'),'financialState','restricted')
$$;

/** 现金依据改变时撤销旧结论的当前效力，保留历史和责任人；此处不改变任何资金状态。 */
CREATE FUNCTION meton_inbox.refresh_cash_dispute(ref uuid) RETURNS meton_inbox.cash_dispute_cases
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c meton_inbox.cash_dispute_cases;b meton_inbox.refund_wire_bindings;x jsonb;digest bytea;
BEGIN
    SELECT * INTO STRICT c FROM meton_inbox.cash_dispute_cases WHERE id=ref FOR UPDATE;
    b.envelope:=c.origin;b.channel:=c.origin#>>'{scope,channel}';b.cash_environment:=c.origin#>>'{scope,cashEnvironment}';b.merchant:=c.origin#>>'{scope,merchant}';
    x:=meton_inbox.all_original_cash_return_exposure(b);
    IF (x->>'pendingCommit')::boolean THEN RETURN NULL; END IF;
    x:=x-'pendingCommit';digest:=sha256(convert_to(x::text,'UTF8'));
    IF c.cash_hash<>digest THEN
        UPDATE meton_inbox.cash_dispute_cases SET cash=x,cash_hash=digest,revision=revision+1,state='pending_review',finding=NULL,reference=NULL,
            updated_at=clock_timestamp(),recorded_xid=pg_current_xact_id() WHERE id=ref RETURNING * INTO c;
        INSERT INTO meton_inbox.cash_dispute_history VALUES(c.id,c.revision,meton_inbox.cash_dispute_value(c),c.epoch,session_user);
    END IF;
    RETURN c;
END $$;

/** 新案只接受当前来源签出的原付款。恢复绑定可以换当前权限，但不能换原账号或原款。 */
CREATE FUNCTION meton_inbox.bind_cash_dispute(route jsonb,proof jsonb) RETURNS jsonb
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
        UPDATE meton_inbox.cash_dispute_cases SET origin=e,epoch=a.epoch,key_ref=a.key_ref WHERE id=c.id;
        c:=meton_inbox.refresh_cash_dispute(c.id);
    END IF;
    RETURN jsonb_build_object('state',CASE WHEN c.id IS NULL OR c.recorded_xid=pg_current_xact_id() THEN 'recorded' ELSE 'bound' END,'id',c.id);
END $$;

/** 复用当前隔离审核身份；过代角色和未重新绑定的恢复案均无权处理。 */
CREATE FUNCTION meton_inbox.require_cash_dispute_review(route jsonb,ref uuid) RETURNS meton_inbox.cash_dispute_cases
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_aftercare_reviewer(route);c meton_inbox.cash_dispute_cases;
BEGIN
    SELECT * INTO c FROM meton_inbox.cash_dispute_cases WHERE id=ref;
    IF c.id IS NULL OR (c.epoch,c.key_ref,c.origin#>>'{scope,deployment}',c.origin#>>'{scope,source}',c.origin#>>'{scope,channel}',c.origin#>>'{scope,cashEnvironment}',c.origin#>>'{scope,merchant}',c.origin#>>'{scope,app}') IS DISTINCT FROM
        (a.epoch,a.key_ref,a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN
        RAISE EXCEPTION 'current original dispute unavailable' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(route,c.origin#>>'{cash,order}',c.origin#>>'{cash,transaction}');
    RETURN meton_inbox.refresh_cash_dispute(c.id);
END $$;
/** 审核读取也刷新原现金版本，不能凭缓存结论发起后续命令。 */
CREATE FUNCTION meton_inbox.cash_dispute_review_context(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c meton_inbox.cash_dispute_cases:=meton_inbox.require_cash_dispute_review(route,ref);
BEGIN
    IF c.id IS NULL OR c.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    RETURN meton_inbox.cash_dispute_value(c);
END $$;

/** 领取、补件和核对结论均绑定原版本与当前现金摘要；同操作重试只交原结果，不重新执行。 */
CREATE FUNCTION meton_inbox.record_cash_dispute_review(route jsonb,ref uuid,op uuid,f jsonb,key_reference text,evidence bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c meton_inbox.cash_dispute_cases:=meton_inbox.require_cash_dispute_review(route,ref);old meton_inbox.cash_dispute_actions;
    action text:=f->>'action';next_state text;finding text:=f->>'finding';allowed boolean;
BEGIN
    IF c.id IS NULL THEN RAISE EXCEPTION 'cash facts not committed' USING ERRCODE='55000'; END IF;
    IF op IS NULL OR (f->>'format'='1' AND f->>'id'=ref::text AND f->>'expected'~'^[1-9][0-9]{0,17}$' AND f->>'cashHash'~'^[0-9a-f]{64}$'
        AND action IN ('claim','request_material','record_material','review') AND f->>'materialHash'~'^[0-9a-f]{64}$'
        AND f->>'reference'~'^[A-Za-z0-9_.:-]{1,120}$' AND length(key_reference) BETWEEN 1 AND 120 AND octet_length(evidence) BETWEEN 29 AND 1572864) IS NOT TRUE
        OR f-ARRAY['format','id','expected','cashHash','action','finding','materialHash','reference']<>'{}'::jsonb THEN
        RAISE EXCEPTION 'invalid original dispute material' USING ERRCODE='22023'; END IF;
    SELECT * INTO old FROM meton_inbox.cash_dispute_actions WHERE (dispute,operation)=(ref,op);
    IF FOUND THEN
        IF old.facts IS DISTINCT FROM f OR old.reviewer<>session_user THEN RAISE EXCEPTION 'dispute operation reused' USING ERRCODE='22023'; END IF;
        RETURN 'recorded'; END IF;
    IF c.recorded_xid=pg_current_xact_id() OR (c.revision,encode(c.cash_hash,'hex')) IS DISTINCT FROM ((f->>'expected')::bigint,f->>'cashHash') THEN
        RAISE EXCEPTION 'original dispute basis changed' USING ERRCODE='40001'; END IF;
    IF action='claim' THEN
        IF c.state<>'pending_review' OR c.assigned_to IS NOT NULL AND c.assigned_to<>session_user AND c.assigned_epoch=c.epoch THEN
            RAISE EXCEPTION 'original dispute already assigned' USING ERRCODE='55000'; END IF;
        next_state:='reviewing';
    ELSE
        IF c.assigned_to IS DISTINCT FROM session_user OR c.assigned_epoch IS DISTINCT FROM c.epoch THEN RAISE EXCEPTION 'assigned reviewer required' USING ERRCODE='42501'; END IF;
        IF action='request_material' AND c.state='reviewing' THEN next_state:='awaiting_material';
        ELSIF action='record_material' AND c.state='awaiting_material' THEN next_state:='reviewing';
        ELSIF action='review' AND c.state='reviewing' THEN
            allowed:=CASE finding
                WHEN 'cash_difference_confirmed' THEN (c.cash->>'knownExcessFen')::numeric>0
                WHEN 'external_return_confirmed' THEN (c.cash->>'externalEvents')::bigint>0 AND (c.cash->>'ambiguousExternalEvents')::bigint=0 AND (c.cash->>'ambiguousRefundEvents')::bigint=0 AND (c.cash->>'ambiguousAlternativeEvents')::bigint=0
                WHEN 'ownership_unresolved' THEN (c.cash->>'ambiguousExternalEvents')::bigint+(c.cash->>'ambiguousRefundEvents')::bigint+(c.cash->>'ambiguousAlternativeEvents')::bigint>0
                WHEN 'payer_amount_unknown' THEN c.cash->>'payerCapFen' IS NULL
                WHEN 'liability_pending' THEN (c.cash->>'externalEvents')::bigint>0 OR (c.cash->>'knownExcessFen')::numeric>0 ELSE false END;
            IF allowed IS NOT TRUE THEN RAISE EXCEPTION 'finding not supported by original cash' USING ERRCODE='22023'; END IF;
            next_state:='reviewed_restricted';
        ELSE RAISE EXCEPTION 'original dispute step differs' USING ERRCODE='55000'; END IF;
    END IF;
    IF action<>'review' AND finding IS NOT NULL THEN RAISE EXCEPTION 'unexpected dispute finding' USING ERRCODE='22023'; END IF;
    UPDATE meton_inbox.cash_dispute_cases SET revision=revision+1,state=next_state,assigned_to=session_user,assigned_epoch=epoch,
        finding=f->>'finding',reference=f->>'reference',updated_at=clock_timestamp(),recorded_xid=pg_current_xact_id() WHERE id=ref RETURNING * INTO c;
    INSERT INTO meton_inbox.cash_dispute_history VALUES(c.id,c.revision,meton_inbox.cash_dispute_value(c),c.epoch,session_user);
    INSERT INTO meton_inbox.cash_dispute_actions VALUES(ref,op,f,c.revision,session_user,key_reference,evidence);
    PERFORM meton_inbox.wake_original_cash_work(ARRAY[c.original]);
    RETURN 'recorded';
END $$;

/** 只有当前结清角色可签出已提交的原进度，恢复后重新绑定同一原款，不继承旧写权。 */
CREATE FUNCTION meton_inbox.cash_dispute_result(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);c meton_inbox.cash_dispute_cases;s jsonb;f jsonb;
BEGIN
    SELECT * INTO c FROM meton_inbox.cash_dispute_cases WHERE id=ref;
    IF c.id IS NULL OR (c.epoch,c.key_ref,c.origin#>>'{scope,deployment}',c.origin#>>'{scope,source}',c.origin#>>'{scope,channel}',c.origin#>>'{scope,cashEnvironment}',c.origin#>>'{scope,merchant}',c.origin#>>'{scope,app}') IS DISTINCT FROM
        (a.epoch,a.key_ref,a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') THEN
        RAISE EXCEPTION 'current dispute binding required' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(route,c.origin#>>'{cash,order}',c.origin#>>'{cash,transaction}');c:=meton_inbox.refresh_cash_dispute(c.id);
    IF c.id IS NULL OR c.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    s:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    f:=jsonb_build_object('format',1,'scope',s,'origin',c.origin,'value',meton_inbox.cash_dispute_value(c),'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','dispute_proved','facts',f,'mac',encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.cash.dispute.status.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;
REVOKE ALL ON FUNCTION meton_inbox.wake_original_cash_work(bytea[]),meton_inbox.cash_dispute_value(meton_inbox.cash_dispute_cases),
    meton_inbox.refresh_cash_dispute(uuid),meton_inbox.bind_cash_dispute(jsonb,jsonb),meton_inbox.require_cash_dispute_review(jsonb,uuid),
    meton_inbox.cash_dispute_review_context(jsonb,uuid),meton_inbox.record_cash_dispute_review(jsonb,uuid,uuid,jsonb,text,bytea),meton_inbox.cash_dispute_result(jsonb,uuid) FROM PUBLIC;
