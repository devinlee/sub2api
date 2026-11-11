-- 原恢复行仍是唯一接续权威；附加内容核对的物理范围，不另建钱包或允许工作者改写历史。
ALTER TABLE public.meton_recovery_successions ADD COLUMN cash_scope jsonb
    CHECK(cash_scope IS NULL OR jsonb_typeof(cash_scope)='object');
DO $columns$
DECLARE body text:=pg_get_functiondef('public.meton_recover_original(text,uuid,uuid,bigint,bigint,text,uuid,uuid,uuid,bigint,uuid,text)'::regprocedure);
    needle text:='INSERT INTO public.meton_recovery_successions VALUES(';
BEGIN
    IF cardinality(string_to_array(body,needle))<>2 THEN RAISE EXCEPTION 'original succession insert changed'; END IF;
    EXECUTE replace(body,needle,'INSERT INTO public.meton_recovery_successions(environment,source,meton_user,restore_id,previous_epoch,next_epoch,account,operation,dispatch,remote_user,source_marker,evidence) VALUES(');
END $columns$;

/** 只有当前离线核对事务能附加一次现金范围；重跑只接受完全相同的原绑定。 */
CREATE FUNCTION public.meton_keep_cash_succession() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE bound jsonb; s jsonb; expected jsonb;
BEGIN
    IF current_user<>pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid='public.meton_recovery_successions'::regclass))
        OR TG_OP='DELETE' THEN RAISE EXCEPTION 'offline cash succession owner required' USING ERRCODE='42501'; END IF;
    IF TG_OP='INSERT' THEN
        IF NEW.cash_scope IS NOT NULL THEN RAISE EXCEPTION 'cash scope requires original succession'; END IF;
        RETURN NEW;
    END IF;
    IF to_jsonb(NEW)-'cash_scope' IS DISTINCT FROM to_jsonb(OLD)-'cash_scope' THEN
        RAISE EXCEPTION 'original succession is immutable'; END IF;
    IF OLD.cash_scope IS NOT NULL THEN
        IF NEW.cash_scope IS DISTINCT FROM OLD.cash_scope THEN RAISE EXCEPTION 'cash succession is immutable'; END IF;
        RETURN NEW;
    END IF;
    bound:=nullif(current_setting('meton.s3_cash_bound',true),'')::jsonb;
    s:=nullif(current_setting('meton.s2_scope',true),'')::jsonb;
    expected:=bound->'physical'||jsonb_build_object('restore',s->>'restore','previous',s->'previous','next',s->'next',
        'material',s->>'material_digest','coverage',bound->>'coverage','catalog',bound->>'catalog');
    IF bound->>'kind' IS DISTINCT FROM 'meton.s3.cash-restored.v1'
        OR bound->'physical'->>'kind' IS DISTINCT FROM 'meton.s3.cash-physical-succession.v1'
        OR bound->'scope' IS DISTINCT FROM jsonb_build_object('environment',s->>'environment','source',s->>'source',
            'restore',s->>'restore','previous',s->'previous','next',s->'next','material',s->>'material_digest')
        OR expected IS NULL OR NEW.cash_scope IS DISTINCT FROM expected
        OR ROW(NEW.environment,NEW.source,NEW.meton_user,NEW.restore_id,NEW.previous_epoch,NEW.next_epoch,
            NEW.account,NEW.operation,NEW.dispatch,NEW.remote_user,NEW.source_marker) IS DISTINCT FROM
           ROW(s->>'environment',s->>'source',(s->>'user')::uuid,(s->>'restore')::uuid,(s->>'previous')::bigint,(s->>'next')::bigint,
            (s->>'account')::uuid,(s->>'creation')::uuid,(s->>'dispatch')::uuid,(s->>'remote_user')::bigint,(s->>'source_marker')::uuid)
        OR expected->>'next_source_system' IS DISTINCT FROM meton_ledger.notification_system_id()
        OR NOT EXISTS(SELECT FROM public.meton_managed_fence WHERE singleton AND NOT enabled
            AND (environment,source,epoch)=(NEW.environment,NEW.source,NEW.previous_epoch)) THEN
        RAISE EXCEPTION 'current cash recovery scope required' USING ERRCODE='42501'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_keep_cash_succession BEFORE INSERT OR UPDATE OR DELETE ON public.meton_recovery_successions
    FOR EACH ROW EXECUTE FUNCTION public.meton_keep_cash_succession();
ALTER TABLE public.meton_recovery_successions ENABLE ALWAYS TRIGGER meton_keep_cash_succession;
REVOKE ALL ON FUNCTION public.meton_keep_cash_succession() FROM PUBLIC;

/** 由原订单和账号取链；物理身份、代次、恢复号及内容摘要在每一跳都必须连续。 */
CREATE FUNCTION meton_ledger.cash_physical_path(marker uuid,start_epoch bigint,start_source text,start_inbox text)
RETURNS TABLE(epoch bigint,source_system text,inbox_system text)
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    WITH RECURSIVE chain(epoch,source_system,inbox_system) AS (
        SELECT start_epoch,start_source,start_inbox
        UNION ALL
        SELECT r.next_epoch,r.cash_scope->>'next_source_system',r.cash_scope->>'next_inbox_system'
        FROM chain c JOIN public.meton_recovery_successions r ON r.source_marker=marker AND r.previous_epoch=c.epoch
        JOIN public.meton_managed_creations m ON m.source_marker=r.source_marker
        WHERE r.next_epoch>r.previous_epoch AND r.next_epoch<=m.epoch
          AND ROW(r.environment,r.source,r.meton_user,r.account,r.operation,r.dispatch,r.remote_user)
            IS NOT DISTINCT FROM ROW(m.environment,m.source,m.meton_user,m.account,m.operation,m.dispatch,m.remote_user)
          AND r.cash_scope->>'kind'='meton.s3.cash-physical-succession.v1'
          AND (r.cash_scope->>'restore')::uuid=r.restore_id
          AND (r.cash_scope->>'previous')::bigint=r.previous_epoch AND (r.cash_scope->>'next')::bigint=r.next_epoch
          AND r.cash_scope->>'material' ~ '^[0-9a-f]{64}$' AND r.cash_scope->>'coverage' ~ '^[0-9a-f]{64}$'
          AND r.cash_scope->>'catalog' ~ '^[0-9a-f]{64}$'
          AND (r.cash_scope->>'previous_source_system',r.cash_scope->>'previous_inbox_system')=(c.source_system,c.inbox_system)
    ) SELECT * FROM chain
$$;
REVOKE ALL ON FUNCTION meton_ledger.cash_physical_path(uuid,bigint,text,text) FROM PUBLIC;

/** 当前消费者只读核实原签名凭证的历史物理范围；本函数不授予旧角色执行权。 */
CREATE FUNCTION meton_ledger.restored_cash_proof_scope(deployment text,source_name text,generation bigint,
    old_source text,old_inbox text,old_epoch bigint,current_inbox text,origin jsonb)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM public.meton_managed_fence f JOIN public.meton_managed_creations m
        ON (m.environment,m.source,m.epoch)=(f.environment,f.source,f.epoch)
        JOIN meton_ledger.cash_orders o ON o.source_marker=m.source_marker AND o.intent_id=(origin->>'intent')::uuid
        CROSS JOIN LATERAL meton_ledger.cash_physical_path(m.source_marker,old_epoch,old_source,old_inbox) p
        WHERE f.singleton AND f.enabled AND (f.environment,f.source,f.epoch)=(deployment,source_name,generation)
          AND old_epoch>0 AND old_epoch<generation
          AND (m.source_marker,m.account,m.meton_user,m.operation) IS NOT DISTINCT FROM
            ((origin->>'sourceMarker')::uuid,(origin->>'account')::uuid,(origin->>'user')::uuid,(origin->>'creation')::uuid)
          AND (o.out_trade_no,o.params_hash) IS NOT DISTINCT FROM (origin->>'order',origin->>'paramsHash')
          AND (p.epoch,p.source_system,p.inbox_system)=(generation,meton_ledger.notification_system_id(),current_inbox))
$$;
REVOKE ALL ON FUNCTION meton_ledger.restored_cash_proof_scope(text,text,bigint,text,text,bigint,text,jsonb) FROM PUBLIC;

/** 原未付款单的迟到事实需要完整内容接续；没有原内容证明仍保留恢复待核对。 */
CREATE OR REPLACE FUNCTION meton_ledger.original_purchase_generation(o meton_ledger.cash_orders,generation bigint)
RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS(SELECT FROM meton_ledger.checkout_handoffs h WHERE
        (h.intent_id,h.source_marker)=(o.intent_id,o.source_marker) AND (h.origin->>'epoch')::bigint=generation)
    OR EXISTS(SELECT FROM meton_ledger.checkout_handoffs h JOIN public.meton_recovery_successions r
        ON r.source_marker=o.source_marker AND r.previous_epoch=(h.origin->>'epoch')::bigint
        CROSS JOIN LATERAL meton_ledger.cash_physical_path(o.source_marker,r.previous_epoch,
            r.cash_scope->>'previous_source_system',r.cash_scope->>'previous_inbox_system') p
        WHERE (h.intent_id,h.source_marker)=(o.intent_id,o.source_marker)
          AND p.epoch=generation AND p.source_system=meton_ledger.notification_system_id()
          AND EXISTS(SELECT FROM public.meton_managed_fence f WHERE f.singleton AND f.enabled
            AND (f.environment,f.source,f.epoch)=(r.environment,r.source,generation)))
$$;
