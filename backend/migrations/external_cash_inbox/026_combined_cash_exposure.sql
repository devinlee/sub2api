-- 三类实际返还按原付款共同计算。重复查询不增加经济事件，同一替代交易号串到不同原付款时保持双方争议。
CREATE FUNCTION meton_inbox.alternative_cash_return_summary(original_key bytea) RETURNS jsonb
LANGUAGE sql SET search_path=pg_catalog,pg_temp AS $$
    WITH candidates AS (
        SELECT o.refund,o.facts,d.proposal,meton_inbox.cash_original_identity(d.proposal->'envelope') original,
            jsonb_build_array(o.facts#>>'{payment,rail}',o.facts#>>'{payment,environment}',o.facts#>>'{payment,merchant}',o.facts->>'transaction') provider_id,
            encode(sha256(convert_to(jsonb_build_array(o.facts->'payment',o.facts->'transaction')::text,'UTF8')),'hex') economic,
            o.recorded_xid=pg_current_xact_id() pending_commit
        FROM meton_inbox.alternative_cash_observations o JOIN meton_inbox.refund_alternative_decisions d USING(refund)
        WHERE o.verb='GET' AND o.facts->>'state'='succeeded'
    ), related AS (SELECT DISTINCT provider_id FROM candidates WHERE original=original_key), grouped AS (
        SELECT c.provider_id,count(DISTINCT c.refund)=1 AND count(DISTINCT c.economic)=1 AND bool_and(
            c.original=original_key AND c.facts->'payment'=c.proposal->'payment' AND c.facts#>>'{payment,currency}'='CNY'
            AND c.facts->>'transaction'~'^[A-Za-z0-9_.:-]{1,120}$' AND c.facts#>>'{payment,fen}'~'^[1-9][0-9]{0,18}$') good,
            max(CASE WHEN c.facts#>>'{payment,fen}'~'^[1-9][0-9]{0,18}$' THEN (c.facts#>>'{payment,fen}')::numeric END) amount,
            bool_or(c.pending_commit) pending_commit,
            string_agg(DISTINCT c.refund::text||':'||c.economic,',' ORDER BY c.refund::text||':'||c.economic) evidence
        FROM candidates c JOIN related r USING(provider_id) GROUP BY c.provider_id
    ) SELECT jsonb_build_object('events',count(*),'knownFen',coalesce(sum(amount) FILTER(WHERE good),0)::text,
        'ambiguousEvents',count(*) FILTER(WHERE good IS NOT TRUE),'pendingCommit',coalesce(bool_or(pending_commit),false),
        'evidence',coalesce(string_agg(evidence,';' ORDER BY provider_id),'')) FROM grouped
$$;

-- 已退金额只进现金合计，不再算未决准备；确定关闭且未出现相反成功事实的原笔也不继续占上限。
CREATE FUNCTION meton_inbox.pending_alternative_cash(original_key bytea,excluded uuid) RETURNS numeric
LANGUAGE sql SET search_path=pg_catalog,pg_temp AS $$
    SELECT coalesce(sum((d.proposal#>>'{payment,fen}')::numeric),0) FROM meton_inbox.refund_alternative_decisions d
        WHERE d.choice='reserved' AND (excluded IS NULL OR d.refund<>excluded)
        AND meton_inbox.cash_original_identity(d.proposal->'envelope')=original_key
        AND NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_observations o WHERE o.refund=d.refund AND o.verb='GET' AND o.facts->>'state'='succeeded')
        AND NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_closures c WHERE c.refund=d.refund AND c.recorded_xid<>pg_current_xact_id()
            AND NOT EXISTS(SELECT FROM meton_inbox.alternative_cash_observations o WHERE o.refund=d.refund AND o.facts->>'state'='succeeded'))
$$;

ALTER FUNCTION meton_inbox.all_original_cash_return_exposure(meton_inbox.refund_wire_bindings) RENAME TO native_external_cash_exposure;
CREATE FUNCTION meton_inbox.all_original_cash_return_exposure(b meton_inbox.refund_wire_bindings) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE x jsonb:=meton_inbox.native_external_cash_exposure(b);
    alt jsonb:=meton_inbox.alternative_cash_return_summary(meton_inbox.cash_original_identity(b.envelope));total numeric;cap numeric;
BEGIN
    total:=(x->>'knownReturnedFen')::numeric+(alt->>'knownFen')::numeric;cap:=(x->>'payerCapFen')::numeric;
    RETURN x||jsonb_build_object('format',2,'alternativeEvents',alt->'events','ambiguousAlternativeEvents',alt->'ambiguousEvents',
        'knownAlternativeFen',alt->>'knownFen','knownReturnedFen',total::text,
        'knownExcessFen',CASE WHEN cap IS NULL THEN NULL ELSE greatest(total-cap,0)::text END,
        'evidenceHash',encode(sha256(convert_to(jsonb_build_array(x->'evidenceHash',alt->'evidence')::text,'UTF8')),'hex'),
        'pendingCommit',(x->>'pendingCommit')::boolean OR (alt->>'pendingCommit')::boolean);
END $$;

/** 正常已退现金参与上限，不因此自动产生争议；强制返还、归属不明或实际超额才交给原核对流程。 */
CREATE OR REPLACE FUNCTION meton_inbox.original_cash_return_exposure(b meton_inbox.refund_wire_bindings) RETURNS jsonb
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE x jsonb:=meton_inbox.all_original_cash_return_exposure(b);
BEGIN
    IF (x->>'externalEvents')::bigint>0 OR (x->>'ambiguousRefundEvents')::bigint>0 OR
        (x->>'ambiguousAlternativeEvents')::bigint>0 OR (x->>'knownExcessFen')::numeric>0 THEN RETURN x; END IF;
    RETURN NULL;
END $$;

DO $cap$
DECLARE name text;body text;first_at integer;last_at integer;point text;
BEGIN
    FOREACH name IN ARRAY ARRAY['meton_inbox.original_alternative_material(jsonb,uuid,uuid)','meton_inbox.prepare_alternative_cash(jsonb,uuid)'] LOOP
        body:=pg_get_functiondef(name::regprocedure);
        point:='SELECT coalesce(sum((x.proposal#>>''{payment,fen}'')::numeric),0) INTO reserved';
        IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative pending cash calculation changed'; END IF;
        first_at:=strpos(body,point);last_at:=first_at+strpos(substr(body,first_at),';');
        body:=substr(body,1,first_at-1)||'reserved:=meton_inbox.pending_alternative_cash(meton_inbox.cash_original_identity(b.envelope),'
            ||CASE WHEN name LIKE '%original_alternative_material%' THEN 'ref' ELSE 'NULL' END||');'||substr(body,last_at);
        point:='(exposure->>''ambiguousRefundEvents'')::bigint=0 AND';
        IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative exposure guard changed'; END IF;
        EXECUTE replace(body,point,point||' (exposure->>''ambiguousAlternativeEvents'')::bigint=0 AND');
    END LOOP;
    -- 刷新这个已有函数的调用绑定，使出站许可摘要同样采用三类现金。
    EXECUTE pg_get_functiondef('meton_inbox.alternative_cash_validation(meton_inbox.refund_alternative_decisions)'::regprocedure);
END $cap$;

-- 替代结清优先于原路结清，因而它的争议凭证也必须携带完整原现金合计，不能只留下一个错误状态。
DO $review$
DECLARE body text:=pg_get_functiondef('meton_inbox.alternative_cash_result(jsonb,uuid)'::regprocedure);point text;
BEGIN
    point:='original jsonb;x meton_inbox.alternative_cash_observations;';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative result declaration changed'; END IF;
    body:=replace(body,point,'exposure jsonb;b meton_inbox.refund_wire_bindings; '||point);
    point:='scope:=jsonb_build_object(';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative review scope changed'; END IF;
    body:=replace(body,point,$new$SELECT * INTO STRICT b FROM meton_inbox.refund_wire_bindings WHERE refund=ref;
    exposure:=meton_inbox.all_original_cash_return_exposure(b);
    IF (exposure->>'pendingCommit')::boolean THEN RETURN jsonb_build_object('state','recorded'); END IF;
    exposure:=exposure-'pendingCommit'; $new$||point);
    point:='jsonb_build_array(original->''state'',(original->''facts'')-ARRAY[''scope'',''validUntil''],conflict)';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative review hash changed'; END IF;
    body:=replace(body,point,'jsonb_build_array(original->''state'',(original->''facts'')-ARRAY[''scope'',''validUntil''],conflict,exposure)');
    point:='''reviewHash'',review_hash,''validUntil''';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative review evidence changed'; END IF;
    EXECUTE replace(body,point,$new$'cashExposure',CASE WHEN conflict THEN exposure END,
        'cashExposureHash',CASE WHEN conflict THEN encode(sha256(convert_to(exposure::text,'UTF8')),'hex') END,'reviewHash',review_hash,'validUntil'$new$);
END $review$;

/** 已知返还和替代在途共同约束新的原路发送；读取或关闭原退款不使用这个发送专用判断。 */
CREATE FUNCTION meton_inbox.original_dispatch_cash_available(e jsonb) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE b meton_inbox.refund_wire_bindings;x jsonb;ref uuid:=(e#>>'{target,refund}')::uuid;pending numeric;
BEGIN
    b.envelope:=e;b.channel:=e#>>'{scope,channel}';b.cash_environment:=e#>>'{scope,cashEnvironment}';b.merchant:=e#>>'{scope,merchant}';
    x:=meton_inbox.all_original_cash_return_exposure(b);pending:=meton_inbox.pending_alternative_cash(meton_inbox.cash_original_identity(e),ref);
    RETURN (x->>'payerCapFen' IS NOT NULL AND NOT (x->>'pendingCommit')::boolean AND
        (x->>'ambiguousExternalEvents')::bigint=0 AND (x->>'ambiguousRefundEvents')::bigint=0 AND (x->>'ambiguousAlternativeEvents')::bigint=0 AND
        (x->>'knownReturnedFen')::numeric+pending+(e#>>'{cash,refundFen}')::numeric<=(x->>'payerCapFen')::numeric) IS TRUE;
END $$;

DO $send$
DECLARE body text;point text;
BEGIN
    body:=pg_get_functiondef('meton_inbox.start_original_refund_transport(jsonb,uuid,uuid,text)'::regprocedure);
    point:='IF send_secret IS NULL';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'native sender cash guard changed'; END IF;
    EXECUTE replace(body,point,'IF NOT meton_inbox.original_dispatch_cash_available((SELECT envelope FROM meton_inbox.refund_wire_bindings WHERE refund=ref)) THEN RETURN NULL; END IF; '||point);
    body:=pg_get_functiondef('meton_inbox.hold_original_refund_transport(jsonb,uuid,uuid,text)'::regprocedure);
    point:='IF io_secret IS NULL';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'native hold cash guard changed'; END IF;
    EXECUTE replace(body,point,'IF NOT meton_inbox.original_dispatch_cash_available((SELECT envelope FROM meton_inbox.refund_wire_bindings WHERE refund=ref)) THEN RETURN false; END IF; '||point);
END $send$;

/** 新成功事实或同交易号归属冲突应重核所有相关原付款，不能只唤醒最后一笔退款。 */
CREATE FUNCTION meton_inbox.wake_combined_cash_reviews() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE originals bytea[];item record;
BEGIN
    IF TG_TABLE_NAME='alternative_cash_observations' THEN
        IF NEW.verb<>'GET' OR NEW.facts->>'state'<>'succeeded' THEN RETURN NEW; END IF;
        SELECT array_agg(DISTINCT meton_inbox.cash_original_identity(d.proposal->'envelope')) INTO originals
            FROM meton_inbox.alternative_cash_observations o JOIN meton_inbox.refund_alternative_decisions d USING(refund)
            WHERE o.verb='GET' AND o.facts->>'state'='succeeded' AND
                (o.facts#>>'{payment,rail}',o.facts#>>'{payment,environment}',o.facts#>>'{payment,merchant}',o.facts->>'transaction')=
                (NEW.facts#>>'{payment,rail}',NEW.facts#>>'{payment,environment}',NEW.facts#>>'{payment,merchant}',NEW.facts->>'transaction');
    ELSE
        SELECT array_agg(DISTINCT meton_inbox.cash_original_identity(b.envelope)) INTO originals
            FROM meton_inbox.refund_positive_cash p JOIN meton_inbox.refund_wire_bindings b USING(refund)
            JOIN meton_inbox.refund_wire_bindings original ON original.refund=NEW.refund
            WHERE (b.channel,b.cash_environment,b.merchant,p.fields->>'refundID')=
                (original.channel,original.cash_environment,original.merchant,NEW.fields->>'refundID');
    END IF;
    FOR item IN SELECT b.refund FROM meton_inbox.refund_wire_bindings b WHERE meton_inbox.cash_original_identity(b.envelope)=ANY(originals) ORDER BY b.refund
    LOOP PERFORM meton_inbox.wake_refund_settlement(item.refund); END LOOP;
    UPDATE meton_inbox.purchase_delivery d SET token=gen_random_uuid(),state='retry',available_at=clock_timestamp(),reason='new_cash_fact'
        WHERE d.review_epoch IS NOT NULL AND EXISTS(SELECT FROM meton_inbox.external_cash_returns x WHERE
            (x.receipt,x.digest)=(d.receipt,d.digest) AND x.original=ANY(originals));
    RETURN NEW;
END $$;
CREATE TRIGGER combined_cash_arrived AFTER INSERT ON meton_inbox.alternative_cash_observations
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.wake_combined_cash_reviews();
ALTER TABLE meton_inbox.alternative_cash_observations ENABLE ALWAYS TRIGGER combined_cash_arrived;
CREATE TRIGGER combined_cash_arrived AFTER INSERT ON meton_inbox.refund_positive_cash
    FOR EACH ROW EXECUTE FUNCTION meton_inbox.wake_combined_cash_reviews();
ALTER TABLE meton_inbox.refund_positive_cash ENABLE ALWAYS TRIGGER combined_cash_arrived;
REVOKE ALL ON FUNCTION meton_inbox.alternative_cash_return_summary(bytea),meton_inbox.pending_alternative_cash(bytea,uuid),
    meton_inbox.all_original_cash_return_exposure(meton_inbox.refund_wire_bindings),meton_inbox.original_dispatch_cash_available(jsonb),meton_inbox.wake_combined_cash_reviews() FROM PUBLIC;
