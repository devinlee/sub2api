-- 停止只永久收回原替代业务号的发送权。是否可以释放资金，仍须确认所有原渠道没有付款。
CREATE TABLE meton_inbox.alternative_cash_stops(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_aftercare_origins,
    reason text NOT NULL CHECK(reason IN ('member_cancel','failed')),
    recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.alternative_cash_stops FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.alternative_cash_stops ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_inbox.alternative_cash_stops FROM PUBLIC;

CREATE TABLE meton_inbox.alternative_cash_closures(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_alternative_decisions,
    terminal jsonb NOT NULL,recorded_xid xid8 NOT NULL DEFAULT pg_current_xact_id()
);
CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.alternative_cash_closures FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate();
ALTER TABLE meton_inbox.alternative_cash_closures ENABLE ALWAYS TRIGGER immutable_fact;
REVOKE ALL ON meton_inbox.alternative_cash_closures FROM PUBLIC;

/** 只能由已验证的原会员停止或原渠道失败调用；锁等到旧传输退出后才把永久停止提交。 */
CREATE FUNCTION meton_inbox.stop_alternative_cash_current(ref uuid,why text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE envelope jsonb;
BEGIN
    SELECT o.envelope INTO envelope FROM meton_inbox.refund_aftercare_origins o WHERE refund=ref;
    IF NOT FOUND THEN RETURN; END IF;
    PERFORM meton_inbox.lock_original_cash(envelope->'scope',envelope#>>'{cash,order}',envelope#>>'{cash,transaction}');
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.refund.alternative.io.v1/'||ref::text,0));
    INSERT INTO meton_inbox.alternative_cash_stops(refund,reason) VALUES(ref,why) ON CONFLICT DO NOTHING;
    IF FOUND THEN
        UPDATE meton_inbox.alternative_cash_jobs SET token=NULL,state='ready',next_at=clock_timestamp() WHERE refund=ref;
        PERFORM meton_inbox.wake_refund_settlement(ref);
    END IF;
END $$;

-- 原会员身份、会话和原意图仍由既有停止入口验证；这里只把原笔取消接回已经批准的替代路径。
DO $member$
DECLARE body text:=pg_get_functiondef('meton_inbox.decide_original_refund(jsonb,jsonb,text,text)'::regprocedure);
    point text:='IF d.target IS DISTINCT FROM target THEN RAISE EXCEPTION ''refund original differs'' USING ERRCODE=''23505''; END IF;';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original member stop changed'; END IF;
    EXECUTE replace(body,point,point||' IF want=''stopped'' THEN PERFORM meton_inbox.stop_alternative_cash_current(ref,''member_cancel''); END IF;');
    body:=pg_get_functiondef('meton_inbox.decide_original_alternative(jsonb,jsonb,text)'::regprocedure);
    point:='IF want=''reserve'' THEN';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative choice changed'; END IF;
    EXECUTE replace(body,point,'IF want=''reserve'' AND EXISTS(SELECT FROM meton_inbox.alternative_cash_stops WHERE refund=ref) THEN want:=''abandon''; END IF; '||point);
END $member$;

-- 旧秘密不能越过已经提交的停止。查询可以保留，不能通过关闭入口再次付款。
DO $fence$
DECLARE body text;point text;
BEGIN
    body:=pg_get_functiondef('meton_inbox.begin_alternative_cash(jsonb,jsonb)'::regprocedure);
    point:='secret:=uuid_send(gen_random_uuid())||uuid_send(gen_random_uuid());';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative start changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_inbox.alternative_cash_stops WHERE refund=d.refund) THEN RETURN NULL; END IF; '||point);
    body:=pg_get_functiondef('meton_inbox.hold_alternative_cash(jsonb,text)'::regprocedure);
    point:='INSERT INTO meton_inbox.alternative_cash_uses(refund)';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative hold changed'; END IF;
    EXECUTE replace(body,point,'IF EXISTS(SELECT FROM meton_inbox.alternative_cash_stops WHERE refund=d.refund) THEN RETURN false; END IF; '||point);
END $fence$;

-- 准备后的停止或已验 GET 失败都永久封闭发送。出现过派发声明，即使没有 uses，也必须以渠道关闭证明排除发送事务回滚后的未知。
DO $prepare$
DECLARE body text:=pg_get_functiondef('meton_inbox.prepare_alternative_cash(jsonb,uuid)'::regprocedure);
    point text:='IF NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=ref) THEN';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative preparation changed'; END IF;
    EXECUTE replace(body,point,$new$
    IF EXISTS(SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref AND verb='GET' AND facts->>'state'='failed') THEN
        PERFORM meton_inbox.stop_alternative_cash_current(ref,'failed');
    END IF;
    IF EXISTS(SELECT FROM meton_inbox.alternative_cash_stops WHERE refund=ref) THEN
        IF EXISTS(SELECT FROM meton_inbox.alternative_cash_stops WHERE refund=ref AND recorded_xid=pg_current_xact_id()) THEN
            RETURN jsonb_build_object('state','recorded'); END IF;
        IF NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=ref) THEN RETURN jsonb_build_object('state','stopped'); END IF;
        mode:=CASE WHEN EXISTS(SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref AND verb='CLOSE') THEN 'query' ELSE 'close' END;
    ELSIF NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=ref) THEN
    $new$);
END $prepare$;

ALTER TABLE meton_inbox.alternative_cash_observations DROP CONSTRAINT alternative_cash_observations_verb_check,
    ADD CHECK(verb IN ('POST','GET','CLOSE'));
DO $observation$
DECLARE body text:=pg_get_functiondef('meton_inbox.record_alternative_cash(jsonb,text,jsonb,bytea,text,bytea)'::regprocedure);
    point text:='verb IS NULL OR verb NOT IN (''POST'',''GET'') OR (verb=''POST'') IS DISTINCT FROM (proof#>>''{facts,mode}''=''send'') OR';
    states text:='''pending'',''succeeded'',''failed'',''not_found''';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 OR cardinality(string_to_array(body,states))<>2 THEN RAISE EXCEPTION 'alternative observation changed'; END IF;
    body:=replace(body,point,$new$verb IS DISTINCT FROM (CASE proof#>>'{facts,mode}' WHEN 'send' THEN 'POST' WHEN 'query' THEN 'GET' WHEN 'close' THEN 'CLOSE' ELSE '' END) OR
        (verb='CLOSE' AND NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_stops WHERE refund=d.refund)) OR$new$);
    EXECUTE replace(body,states,states||',''closed''');
END $observation$;

/** 独立库先永久禁止所有新发送，再签已提交的双渠道未付证明。查无或失败都不是关闭事实。 */
CREATE FUNCTION meton_inbox.alternative_cash_closed(route jsonb,ref uuid) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);d meton_inbox.refund_alternative_decisions;
    stopped meton_inbox.alternative_cash_stops;verification jsonb;reason text;terminal jsonb;f jsonb;scope jsonb;
    b meton_inbox.refund_wire_bindings;original_closed jsonb;kept meton_inbox.alternative_cash_closures;
BEGIN
    PERFORM meton_inbox.original_alternative_decision(route,ref);
    SELECT * INTO d FROM meton_inbox.refund_alternative_decisions WHERE refund=ref AND choice='reserved';
    IF NOT FOUND THEN RETURN jsonb_build_object('state','alternative_pending'); END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('meton.refund.alternative.io.v1/'||ref::text,0));
    SELECT * INTO stopped FROM meton_inbox.alternative_cash_stops WHERE refund=ref;
    IF NOT FOUND THEN RETURN jsonb_build_object('state','alternative_pending'); END IF;
    IF stopped.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    verification:=meton_inbox.original_refund_aftercare_result(route,ref);
    IF verification->>'state'='recorded' THEN RETURN verification; END IF;
    IF verification->>'state' IS DISTINCT FROM 'verification_proved' OR verification#>>'{facts,verification,channelState}' IS DISTINCT FROM 'closed_unpaid' THEN
        RETURN jsonb_build_object('state','alternative_pending'); END IF;
    IF EXISTS(SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref AND facts->>'state'='succeeded') THEN
        RETURN jsonb_build_object('state','alternative_pending'); END IF;
    IF NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_attempts WHERE refund=ref) THEN reason:='unsent';
    ELSE
        IF NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref AND verb='GET' AND facts->>'state'='closed') THEN
            RETURN jsonb_build_object('state','alternative_pending'); END IF;
        IF EXISTS(SELECT FROM meton_inbox.alternative_cash_observations WHERE refund=ref AND verb='GET' AND facts->>'state'='closed' AND recorded_xid=pg_current_xact_id()) THEN
            RETURN jsonb_build_object('state','recorded'); END IF;
        reason:='channel_closed';
    END IF;
    -- 终结证据只绑定不可变的原决定和确定结局；后续查询时间、签名轮换不产生第二份释放凭证。
    SELECT * INTO STRICT b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    SELECT fields INTO original_closed FROM meton_inbox.refund_resolution_samples(b) WHERE transport IN ('GET','callback') AND reported='CLOSED'
        AND correct_owner AND NOT conflicted ORDER BY fields::text LIMIT 1;
    IF original_closed IS NULL THEN RETURN jsonb_build_object('state','alternative_pending'); END IF;
    terminal:=jsonb_build_object('ticket',d.ticket,'reason',reason,'stopReason',stopped.reason,'originalChannel','closed_unpaid','originalClosed',original_closed);
    INSERT INTO meton_inbox.alternative_cash_closures(refund,terminal) VALUES(ref,terminal) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT kept FROM meton_inbox.alternative_cash_closures WHERE refund=ref;
    IF kept.terminal IS DISTINCT FROM terminal THEN RETURN jsonb_build_object('state','alternative_pending'); END IF;
    IF kept.recorded_xid=pg_current_xact_id() THEN RETURN jsonb_build_object('state','recorded'); END IF;
    scope:=jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id());
    f:=jsonb_build_object('format',1,'state','alternative_closed','scope',scope,'proposal',d.proposal,'terminal',terminal,
        'terminalHash',encode(sha256(convert_to(terminal::text,'UTF8')),'hex'),'validUntil',clock_timestamp()+interval '25 seconds');
    RETURN jsonb_build_object('state','alternative_closed','facts',f,'mac',encode(meton_inbox.refund_seal_mac(
        convert_to(jsonb_build_array('meton.refund.alternative.closed.v1',f)::text,'UTF8'),a.seal_key),'hex'));
END $$;

DO $result$
DECLARE body text:=pg_get_functiondef('meton_inbox.alternative_cash_result(jsonb,uuid)'::regprocedure);
    point text:='IF n=0 AND NOT conflict THEN RETURN jsonb_build_object(''state'',''alternative_pending''); END IF;';
    failed text:='facts->>''state''=''failed''';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 OR cardinality(string_to_array(body,failed))<>2 THEN RAISE EXCEPTION 'alternative cash result changed'; END IF;
    body:=replace(body,failed,'facts->>''state'' IN (''failed'',''closed'')');
    EXECUTE replace(body,point,'IF n=0 AND NOT conflict THEN RETURN meton_inbox.alternative_cash_closed(route,ref); END IF;');
    body:=pg_get_functiondef('meton_inbox.finish_alternative_cash(jsonb,uuid,uuid,text)'::regprocedure);
    IF cardinality(string_to_array(body,'''pending'',''review'',''success'''))<>2 OR cardinality(string_to_array(body,'''review'',''success'''))<>3 THEN
        RAISE EXCEPTION 'alternative work finish changed'; END IF;
    body:=replace(body,'''pending'',''review'',''success''','''pending'',''review'',''success'',''closed''');
    EXECUTE replace(body,'result IN (''review'',''success'')','result IN (''review'',''success'',''closed'')');
    body:=pg_get_functiondef('meton_inbox.finish_refund_settlement(jsonb,uuid,bigint,uuid,text)'::regprocedure);
    EXECUTE replace(body,'''settled'',''review''','''settled'',''released'',''review''');
END $result$;

-- 双渠道关闭已经独立提交的原笔不再占用替代现金上限；后来出现相反付款事实时，原占用重新参加核对。
DO $cash_cap$
DECLARE body text;name text;point text:='WHERE x.choice=''reserved'' AND';
BEGIN
    FOREACH name IN ARRAY ARRAY['meton_inbox.original_alternative_material(jsonb,uuid,uuid)','meton_inbox.prepare_alternative_cash(jsonb,uuid)'] LOOP
        body:=pg_get_functiondef(name::regprocedure);
        IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original alternative cash cap changed'; END IF;
        EXECUTE replace(body,point,$new$WHERE x.choice='reserved' AND NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_closures c WHERE c.refund=x.refund
            AND c.recorded_xid<>pg_current_xact_id() AND NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_observations o WHERE o.refund=x.refund AND o.facts->>'state'='succeeded')) AND$new$);
    END LOOP;
    body:=pg_get_functiondef('meton_inbox.original_refund_wire_risk(jsonb)'::regprocedure);
    point:='original_trade:=meton_inbox.lock_original_cash(s,k->>''order'',k->>''transaction'');';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original cash risk changed'; END IF;
    EXECUTE replace(body,point,point||$new$
    IF EXISTS(SELECT FROM meton_inbox.alternative_cash_closures c JOIN meton_inbox.refund_alternative_decisions d USING(refund)
        JOIN meton_inbox.alternative_cash_observations o USING(refund) WHERE o.facts->>'state'='succeeded'
            AND meton_inbox.cash_original_identity(d.proposal->'envelope')=meton_inbox.cash_original_identity(e)) THEN RETURN 'alternative_cash_conflict'; END IF;
    $new$);
END $cash_cap$;
REVOKE ALL ON FUNCTION meton_inbox.stop_alternative_cash_current(uuid,text),meton_inbox.alternative_cash_closed(jsonb,uuid) FROM PUBLIC;
