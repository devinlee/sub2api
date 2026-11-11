-- 售后原因也属于原决定的签名材料，供当前来源恢复使用；历史审批和现金身份保持不变。
DO $original$
DECLARE body text:=pg_get_functiondef('meton_inbox.original_alternative_decision(jsonb,uuid)'::regprocedure);
    point text:='''proposal'',d.proposal,''choice'',d.choice';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original alternative decision changed'; END IF;
    EXECUTE replace(body,point,$new$'aftercare',(SELECT jsonb_build_object('envelope',envelope,'reason',reason)
        FROM meton_inbox.refund_aftercare_origins WHERE refund=ref),'proposal',d.proposal,'choice',d.choice$new$);
END $original$;

ALTER TABLE meton_inbox.alternative_cash_jobs ADD COLUMN authority_epoch bigint, ADD COLUMN authority_key uuid,
    ADD CHECK((authority_epoch IS NULL)=(authority_key IS NULL));

-- 复用已有的原退款有界扫描。新签章重核已停队列；有发送声明的原号仍只能查询，不重新产生现金尝试。
DO $recheck$
DECLARE body text:=pg_get_functiondef('meton_inbox.recheck_original_refund_work(jsonb,meton_inbox.refund_gate_authorities)'::regprocedure);
    point text:='seen:=chunk[cardinality(chunk)];';
BEGIN
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'original refund recheck changed'; END IF;
    EXECUTE replace(body,point,point||$new$
        UPDATE meton_inbox.alternative_cash_jobs w SET token=NULL,next_at=clock_timestamp(),state='ready'
            WHERE w.refund=ANY(chunk) AND (w.authority_epoch,w.authority_key) IS DISTINCT FROM (a.epoch,a.key_ref);
    $new$);
    body:=pg_get_functiondef('meton_inbox.claim_alternative_cash(jsonb)'::regprocedure);
    point:='SELECT x.* INTO j FROM meton_inbox.alternative_cash_jobs x';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative claim changed'; END IF;
    body:=replace(body,point,'PERFORM meton_inbox.recheck_original_refund_work(route,a); '||point);
    point:='SET token=gen_random_uuid(),next_at=';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative claim stamp changed'; END IF;
    EXECUTE replace(body,point,'SET authority_epoch=a.epoch,authority_key=a.key_ref,token=gen_random_uuid(),next_at=');
    body:=pg_get_functiondef('meton_inbox.finish_alternative_cash(jsonb,uuid,uuid,text)'::regprocedure);
    point:='PERFORM meton_inbox.require_refund_resolver(route);';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative finish authority changed'; END IF;
    body:=replace(body,'BEGIN','DECLARE a meton_inbox.refund_gate_authorities; BEGIN');
    body:=replace(body,point,'a:=meton_inbox.require_refund_resolver(route);');
    point:='WHERE refund=ref AND token=lease';
    IF cardinality(string_to_array(body,point))<>2 THEN RAISE EXCEPTION 'alternative finish lease changed'; END IF;
    EXECUTE replace(body,point,'WHERE authority_epoch=a.epoch AND authority_key=a.key_ref AND refund=ref AND token=lease');
END $recheck$;
