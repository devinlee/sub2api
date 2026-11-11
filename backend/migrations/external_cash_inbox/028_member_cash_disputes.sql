-- 会员材料与人工裁决分权；独立保存原操作，使来源响应丢失后仍能只查原号。
CREATE TABLE meton_inbox.cash_dispute_member_roles(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,key_ref uuid NOT NULL,member_role name NOT NULL,
    PRIMARY KEY(deployment,source,epoch,key_ref)
);
CREATE TABLE meton_inbox.cash_dispute_submissions(
    dispute uuid NOT NULL REFERENCES meton_inbox.cash_dispute_cases,operation uuid NOT NULL,request jsonb NOT NULL,
    subject jsonb NOT NULL,revision bigint NOT NULL,key_ref text NOT NULL,sealed bytea NOT NULL,
    PRIMARY KEY(dispute,operation),FOREIGN KEY(dispute,revision) REFERENCES meton_inbox.cash_dispute_history
);
DO $protect$ DECLARE n text;BEGIN
    FOREACH n IN ARRAY ARRAY['cash_dispute_member_roles','cash_dispute_submissions'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.keep_refund_gate()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER immutable_fact',n);
    END LOOP;
END $protect$;
REVOKE ALL ON meton_inbox.cash_dispute_member_roles,meton_inbox.cash_dispute_submissions FROM PUBLIC;

/** 公开投影不含审核员身份、内部引用或材料正文；原操作存在与案件当前进度分别表达。 */
CREATE FUNCTION meton_inbox.member_cash_dispute_value(c meton_inbox.cash_dispute_cases,s meton_inbox.cash_dispute_submissions,result text) RETURNS jsonb
LANGUAGE sql SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('state',result,'id',c.id,'revision',c.revision,'phase',c.state,'financialState','restricted','finding',c.finding,
        'submission',CASE WHEN s.operation IS NULL THEN NULL ELSE jsonb_build_object('operation',s.operation,'kind',s.request->>'kind',
            'revision',s.revision,'materialHash',s.request->>'materialHash') END)
$$;

/** 签名的当前会话证明只允许在原案件提交或查询；旧角色、其他账号及会员自报审核结论均不能使用。 */
CREATE FUNCTION meton_inbox.member_cash_dispute(proof jsonb,key_reference text,evidence bytea) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE f jsonb:=proof->'facts';scope jsonb:=f->'scope';a meton_inbox.refund_gate_authorities;c meton_inbox.cash_dispute_cases;
    s meton_inbox.cash_dispute_submissions;r jsonb:=f->'request';owner jsonb;op uuid:=(f->>'operation')::uuid;
BEGIN
    SELECT * INTO a FROM meton_inbox.refund_gate_authorities WHERE (deployment,source)=(scope->>'deployment',scope->>'source') FOR SHARE;
    IF a.key_ref IS NULL OR scope IS DISTINCT FROM jsonb_build_object('deployment',a.deployment,'source',a.source,'epoch',a.epoch,'keyRef',a.key_ref,
        'sourceSystem',a.source_system,'inboxSystem',meton_inbox.system_id()) OR NOT EXISTS(SELECT FROM meton_inbox.cash_dispute_member_roles m
        WHERE (m.deployment,m.source,m.epoch,m.key_ref,m.member_role)=(a.deployment,a.source,a.epoch,a.key_ref,session_user)) OR
        pg_has_role(session_user,current_user,'MEMBER') OR pg_is_in_recovery() OR current_setting('session_replication_role')<>'origin' OR
        f->>'format' IS DISTINCT FROM '1' OR f->>'action' NOT IN ('dispute_submit','dispute_status') OR op IS NULL OR
        ((f->>'validUntil')::timestamptz BETWEEN clock_timestamp() AND clock_timestamp()+interval '5 seconds') IS NOT TRUE OR
        proof->>'mac' IS DISTINCT FROM encode(meton_inbox.refund_seal_mac(convert_to(jsonb_build_array('meton.cash.dispute.member.v1',f)::text,'UTF8'),a.seal_key),'hex') THEN
        RAISE EXCEPTION 'current member dispute proof required' USING ERRCODE='42501'; END IF;
    SELECT * INTO c FROM meton_inbox.cash_dispute_cases WHERE id=(f->>'dispute')::uuid;
    owner:=jsonb_build_array(c.origin#>'{owner,user}',c.origin#>'{owner,account}',c.origin#>'{owner,source_marker}',
        c.origin#>'{target,nativeOrder}',c.origin#>'{target,payment}',c.origin#>'{target,cutoff}');
    IF c.id IS NULL OR (c.epoch,c.key_ref,c.origin#>>'{scope,deployment}',c.origin#>>'{scope,source}') IS DISTINCT FROM
        (a.epoch,a.key_ref,a.deployment,a.source) OR f->'owner' IS DISTINCT FROM owner OR f->>'original' IS DISTINCT FROM encode(c.original,'hex') OR
        f#>>'{subject,user}' IS DISTINCT FROM c.origin#>>'{owner,user}' THEN
        RAISE EXCEPTION 'original member dispute differs' USING ERRCODE='42501'; END IF;
    PERFORM meton_inbox.lock_original_cash(c.origin->'scope',c.origin#>>'{cash,order}',c.origin#>>'{cash,transaction}');
    c:=meton_inbox.refresh_cash_dispute(c.id);
    IF c.id IS NULL THEN RAISE EXCEPTION 'original cash not committed' USING ERRCODE='55000'; END IF;
    SELECT * INTO s FROM meton_inbox.cash_dispute_submissions WHERE (dispute,operation)=(c.id,op);
    IF f->>'action'='dispute_status' THEN
        IF r IS DISTINCT FROM 'null'::jsonb OR key_reference IS NOT NULL OR evidence IS NOT NULL THEN
            RAISE EXCEPTION 'read cannot submit material' USING ERRCODE='22023'; END IF;
        RETURN meton_inbox.member_cash_dispute_value(c,s,'observed');
    END IF;
    IF (r->>'format'='1' AND r->>'dispute'=c.id::text AND r->>'operation'=op::text AND r->>'original'=encode(c.original,'hex')
        AND r->'authority'=jsonb_build_array(a.deployment,a.source) AND r->'owner'=owner
        AND r->>'expected'~'^[1-9][0-9]{0,17}$' AND r->>'kind' IN ('appeal','supplement') AND r->>'materialHash'~'^[0-9a-f]{64}$'
        AND length(key_reference) BETWEEN 1 AND 120 AND octet_length(evidence) BETWEEN 29 AND 1572864) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid original member material' USING ERRCODE='22023'; END IF;
    IF s.operation IS NOT NULL THEN
        IF s.request IS DISTINCT FROM r THEN RAISE EXCEPTION 'member operation reused' USING ERRCODE='23505'; END IF;
        RETURN meton_inbox.member_cash_dispute_value(c,s,'observed');
    END IF;
    IF c.revision<>(r->>'expected')::bigint THEN RETURN meton_inbox.member_cash_dispute_value(c,s,'stale'); END IF;
    IF NOT (r->>'kind'='appeal' AND c.state IN ('pending_review','reviewed_restricted') OR r->>'kind'='supplement' AND c.state='awaiting_material') THEN
        RETURN meton_inbox.member_cash_dispute_value(c,s,'phase_conflict'); END IF;
    UPDATE meton_inbox.cash_dispute_cases SET revision=revision+1,
        state=CASE WHEN r->>'kind'='supplement' AND assigned_epoch=epoch THEN 'reviewing' ELSE 'pending_review' END,
        finding=NULL,reference=NULL,updated_at=clock_timestamp(),recorded_xid=pg_current_xact_id() WHERE id=c.id RETURNING * INTO c;
    INSERT INTO meton_inbox.cash_dispute_history VALUES(c.id,c.revision,meton_inbox.cash_dispute_value(c),c.epoch,session_user);
    INSERT INTO meton_inbox.cash_dispute_submissions VALUES(c.id,op,r,f->'subject',c.revision,key_reference,evidence) RETURNING * INTO s;
    PERFORM meton_inbox.wake_original_cash_work(ARRAY[c.original]);
    RETURN meton_inbox.member_cash_dispute_value(c,s,'observed');
END $$;

/** 仅当前审核员能取原案材料；提交角色与普通来源查询身份不能读取正文。 */
CREATE FUNCTION meton_inbox.cash_dispute_submission_material(route jsonb,ref uuid,op uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c meton_inbox.cash_dispute_cases:=meton_inbox.require_cash_dispute_review(route,ref);s meton_inbox.cash_dispute_submissions;
BEGIN
    IF c.id IS NULL THEN RAISE EXCEPTION 'cash facts not committed' USING ERRCODE='55000'; END IF;
    SELECT * INTO s FROM meton_inbox.cash_dispute_submissions WHERE (dispute,operation)=(ref,op);
    IF s.operation IS NULL THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('request',s.request,'keyRef',s.key_ref,'sealed',encode(s.sealed,'base64'));
END $$;
REVOKE ALL ON FUNCTION meton_inbox.member_cash_dispute_value(meton_inbox.cash_dispute_cases,meton_inbox.cash_dispute_submissions,text),
    meton_inbox.member_cash_dispute(jsonb,text,bytea),meton_inbox.cash_dispute_submission_material(jsonb,uuid,uuid) FROM PUBLIC;
