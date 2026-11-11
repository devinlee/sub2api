-- 旧订单仍以原来源库、原冻结截点和原订单号定位。登记只接续处理权，不产生余额、赠送或退款。
CREATE UNIQUE INDEX legacy_cutoff_owner ON meton_ledger.legacy_balance_fences(cutoff,source_marker);
CREATE TABLE meton_ledger.legacy_cash_handoffs(
    cutoff uuid NOT NULL, source_marker uuid NOT NULL, native_order bigint NOT NULL,
    kind text GENERATED ALWAYS AS ('order'::text) STORED, proof_hash bytea NOT NULL CHECK(octet_length(proof_hash)=32),
    PRIMARY KEY(cutoff,native_order), UNIQUE(source_marker,native_order),
    FOREIGN KEY(cutoff,source_marker) REFERENCES meton_ledger.legacy_balance_fences(cutoff,source_marker),
    FOREIGN KEY(cutoff,kind,native_order) REFERENCES meton_ledger.legacy_cash_facts(cutoff,kind,native_id)
);
CREATE TRIGGER immutable_handoff BEFORE UPDATE OR DELETE ON meton_ledger.legacy_cash_handoffs
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event();
ALTER TABLE meton_ledger.legacy_cash_handoffs ENABLE ALWAYS TRIGGER immutable_handoff;
REVOKE ALL ON meton_ledger.legacy_cash_handoffs FROM PUBLIC;

CREATE INDEX legacy_pending_order_audit ON meton_ledger.legacy_cash_facts(cutoff,(proof->>'order_id'),native_id)
    WHERE kind='order_audit';
CREATE INDEX legacy_provider_cash_trade ON meton_ledger.legacy_cash_facts((proof->>'provider_key'),(proof->>'provider_instance'),(proof->>'trade_ref'))
    WHERE kind='order' AND proof->>'trade_ref' IS NOT NULL;
CREATE INDEX legacy_provider_cash_order ON meton_ledger.legacy_cash_facts((proof->>'provider_key'),(proof->>'provider_instance'),(proof->>'merchant_ref'))
    WHERE kind='order' AND proof->>'merchant_ref' IS NOT NULL;

CREATE FUNCTION meton_ledger.require_legacy_cash_cutoff(o jsonb,original uuid) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE header jsonb;
BEGIN
    IF o->>'source_system' IS DISTINCT FROM meton_ledger.notification_system_id() THEN
        RAISE EXCEPTION 'wrong original cash database' USING ERRCODE='42501'; END IF;
    header:=meton_ledger.find_legacy_cash(o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'creation')::uuid,
        (o->>'user')::uuid,(o->>'account')::uuid,(o->>'dispatch')::uuid,(o->>'remote_user')::bigint,(o->>'source_marker')::uuid,original);
    IF header->>'cash_state' IS DISTINCT FROM 'cash_evidence_frozen' OR NOT meton_ledger.legacy_activity_guards_ready() OR NOT meton_ledger.legacy_opening_guards_ready()
       OR NOT EXISTS(SELECT FROM meton_ledger.legacy_activity_manifests a JOIN meton_ledger.legacy_balance_fences b USING(cutoff)
           WHERE a.cutoff=original AND a.captured_xid=b.cutoff_xid) THEN
        RAISE EXCEPTION 'original historical cash cutoff unavailable' USING ERRCODE='42501'; END IF;
END $$;

-- 分页键来自不可变的 S2 订单清单。响应丢失时按原页再查，已经接收的订单也在结果内。
CREATE FUNCTION meton_ledger.accept_legacy_cash_page(o jsonb,original uuid,after_order bigint,page_size integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE marker uuid:=(o->>'source_marker')::uuid; orders bigint[]; cursor_id bigint; more_orders boolean;
BEGIN
    IF (after_order>=0 AND page_size BETWEEN 1 AND 100 AND original IS NOT NULL) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid historical order page' USING ERRCODE='22023'; END IF;
    PERFORM meton_ledger.require_cash_writer(o->>'environment',o->>'source',(o->>'epoch')::bigint);
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock(marker));
    PERFORM meton_ledger.require_legacy_cash_cutoff(o,original);
    -- 先证明截点确已存在，再复用已验的切换角色、主库和行锁检查。导入不能顺便冻结另一个账号。
    PERFORM meton_ledger.freeze_legacy_balance(o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'creation')::uuid,
        (o->>'user')::uuid,(o->>'account')::uuid,(o->>'dispatch')::uuid,(o->>'remote_user')::bigint,marker,original);
    SELECT coalesce(array_agg(f.native_id ORDER BY f.native_id),'{}'::bigint[]) INTO orders FROM
        (SELECT native_id FROM meton_ledger.legacy_cash_facts WHERE cutoff=original AND kind='order' AND native_id>after_order
         ORDER BY native_id LIMIT page_size) f;
    INSERT INTO meton_ledger.legacy_cash_handoffs(cutoff,source_marker,native_order,proof_hash)
        SELECT original,marker,native_id,sha256(convert_to(proof::text,'UTF8')) FROM meton_ledger.legacy_cash_facts
        WHERE cutoff=original AND kind='order' AND native_id=ANY(orders) ORDER BY native_id ON CONFLICT(cutoff,native_order) DO NOTHING;
    IF (SELECT count(*) FROM meton_ledger.legacy_cash_handoffs i JOIN meton_ledger.legacy_cash_facts f
        ON (f.cutoff,f.kind,f.native_id)=(i.cutoff,i.kind,i.native_order) WHERE i.cutoff=original AND i.source_marker=marker AND i.native_order=ANY(orders)
        AND i.proof_hash=sha256(convert_to(f.proof::text,'UTF8')))<>cardinality(orders) THEN
        RAISE EXCEPTION 'historical handoff differs' USING ERRCODE='23514'; END IF;
    cursor_id:=coalesce(orders[cardinality(orders)],after_order);
    more_orders:=EXISTS(SELECT FROM meton_ledger.legacy_cash_facts WHERE cutoff=original AND kind='order' AND native_id>cursor_id);
    -- 走到末页只说明游标用完；即使操作员从中间开始，也须与完整冻结清单核对才能交回全部已接收。
    RETURN jsonb_build_object('cutoff',original,'sourceMarker',marker,'orders',to_jsonb(orders),'next',cursor_id,'more',more_orders,
        'allOrdersHandedOff',NOT more_orders AND NOT EXISTS(SELECT FROM meton_ledger.legacy_cash_facts f
            WHERE f.cutoff=original AND f.kind='order' AND NOT EXISTS(SELECT FROM meton_ledger.legacy_cash_handoffs h
                WHERE (h.cutoff,h.source_marker,h.native_order)=(original,marker,f.native_id))));
END $$;

-- 原程序 toPaid 在 ORDER_PAID 记录实际金额与渠道交易号。须逐项对上截点哈希和原单，不能以报价或找不到额度代替实付。
CREATE FUNCTION meton_ledger.legacy_verified_payment(f jsonb,expected text,raw text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE detail jsonb; amount numeric;
BEGIN
    IF raw IS NULL OR octet_length(raw)>65536 OR meton_ledger.legacy_hash(raw) IS DISTINCT FROM expected OR f->>'currency_evidence' IS DISTINCT FROM 'CNY'
        THEN RETURN NULL; END IF;
    BEGIN detail:=raw::jsonb; EXCEPTION WHEN data_exception THEN RETURN NULL; END;
    IF jsonb_typeof(detail->'tradeNo') IS DISTINCT FROM 'string' OR nullif(detail->>'tradeNo','') IS NULL OR
        meton_ledger.legacy_hash(detail->>'tradeNo') IS DISTINCT FROM f->>'trade_ref' OR jsonb_typeof(detail->'paidAmount') IS DISTINCT FROM 'number' THEN RETURN NULL; END IF;
    amount:=(detail->>'paidAmount')::numeric;
    IF amount<=0 OR trunc(amount,2)<>amount OR amount IS DISTINCT FROM (f->>'order_pay_amount')::numeric THEN RETURN NULL; END IF;
    RETURN amount::numeric(20,2);
END $$;

-- 经济基准来自 S2 已核实的购买凭证或可核对的旧实付。当前余额、手机号及新的商品定价均不参与。
CREATE FUNCTION meton_ledger.read_legacy_cash_order(o jsonb,original uuid,p_order bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE f jsonb; stored_hash bytea; marker uuid:=(o->>'source_marker')::uuid; source_basis jsonb; state text; basis text;
    references_complete boolean; disputed boolean; refund_audit boolean; actual_paid numeric; paid_audit bigint; credit_audit boolean;
BEGIN
    PERFORM meton_ledger.require_legacy_cash_cutoff(o,original);
    SELECT c.proof,h.proof_hash INTO f,stored_hash FROM meton_ledger.legacy_cash_handoffs h JOIN meton_ledger.legacy_cash_facts c
        ON (c.cutoff,c.kind,c.native_id)=(h.cutoff,h.kind,h.native_order)
        WHERE (h.cutoff,h.source_marker,h.native_order)=(original,marker,p_order);
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF stored_hash<>sha256(convert_to(f::text,'UTF8')) THEN RAISE EXCEPTION 'historical order evidence differs' USING ERRCODE='55000'; END IF;
    -- 仅接受本截点已启用的源批次。已消耗至零的原购买仍保留原本金和原数量，不能用期初剩余量替换分母。
    SELECT jsonb_build_object('origin',c.origin,'review',a.review,'opening',a.operation,'creditEvent',e.event_id,'unit',r.unit,
        'denomination',c.denomination,'ruleVersion',c.rule_version,'faceValue',c.face_value::text,'conversionRate',c.conversion_rate::text,
        'originalUnits',c.original_amount::text,'openingUnits',c.remaining::text,'evidence',c.evidence_ref)
        INTO source_basis FROM meton_ledger.legacy_source_openings a JOIN meton_ledger.legacy_source_reviews r ON (r.operation,r.cutoff)=(a.review,a.cutoff)
        JOIN meton_ledger.legacy_source_components c ON c.review=a.review LEFT JOIN meton_ledger.legacy_opening_events e
        ON (e.cutoff,e.review,e.ordinal)=(a.cutoff,a.review,c.ordinal)
        WHERE (a.cutoff,a.source_marker,c.native_kind,c.native_id,c.kind)=(original,marker,'order',p_order,'purchase')
          AND (c.remaining=0 OR e.event_id IS NOT NULL);
    SELECT meton_ledger.legacy_verified_payment(f,a.proof->>'detail_digest',l.detail),a.native_id INTO actual_paid,paid_audit
        FROM meton_ledger.legacy_cash_facts a JOIN public.payment_audit_logs l ON l.id=a.native_id AND l.order_id=p_order::text AND l.action='ORDER_PAID'
        WHERE (a.cutoff,a.kind,a.proof->>'order_id',a.proof->>'action')=(original,'order_audit',p_order::text,'ORDER_PAID');
    credit_audit:=EXISTS(SELECT FROM meton_ledger.legacy_cash_facts a WHERE
        (a.cutoff,a.kind,a.proof->>'order_id',a.proof->>'action')=(original,'order_audit',p_order::text,'RECHARGE_SUCCESS'));
    references_complete:=coalesce(f->>'currency_evidence'='CNY' AND nullif(f->>'provider_key','') IS NOT NULL AND nullif(f->>'provider_instance','') IS NOT NULL
        AND f->>'trade_ref' IS NOT NULL AND f->>'merchant_ref' IS NOT NULL,false);
    disputed:=EXISTS(SELECT FROM meton_ledger.legacy_cash_facts sibling JOIN meton_ledger.legacy_balance_fences b ON b.cutoff=sibling.cutoff
        JOIN public.meton_managed_creations m ON m.source_marker=b.source_marker WHERE sibling.kind='order' AND (m.environment,m.source)=(o->>'environment',o->>'source')
          AND (sibling.cutoff,sibling.native_id)<>(original,p_order)
          AND (sibling.proof->>'provider_key',sibling.proof->>'provider_instance')=(f->>'provider_key',f->>'provider_instance')
          AND (sibling.proof->>'trade_ref'=f->>'trade_ref' OR sibling.proof->>'merchant_ref'=f->>'merchant_ref'));
    refund_audit:=EXISTS(SELECT FROM meton_ledger.legacy_cash_facts a WHERE a.cutoff=original AND a.kind='order_audit'
        AND a.proof->>'order_id'=p_order::text AND a.proof->>'action' LIKE 'REFUND%');
    basis:='unresolved';
    IF source_basis IS NOT NULL THEN basis:='purchased_source';
    ELSIF NOT disputed AND references_complete AND actual_paid IS NOT NULL AND NOT credit_audit AND f->>'order_type'='balance'
        AND f->>'paid_at' IS NOT NULL AND f->>'completed_at' IS NULL
        AND f->>'redemption_match'='unclaimed' AND f->>'code_ref' IS NOT NULL AND (f->>'bonus')::numeric=0
        AND f->>'state' IN ('PAID','RECHARGING','REFUND_REQUESTED','REFUNDING','REFUND_PENDING','REFUND_FAILED','REFUNDED','PARTIALLY_REFUNDED')
        THEN basis:='unposted_cash'; END IF;
    state:=CASE WHEN disputed THEN 'payment_conflict'
        WHEN refund_audit OR f->>'state' IN ('REFUND_REQUESTED','REFUNDING','REFUND_PENDING','REFUND_FAILED','REFUNDED','PARTIALLY_REFUNDED')
          OR f->>'refund_requested_at' IS NOT NULL OR f->>'refund_at' IS NOT NULL OR (f->>'reported_refund')::numeric<>0 OR f->>'forced_refund'='true' THEN 'refund_review'
        WHEN basis='purchased_source' THEN 'source_opened' WHEN basis='unposted_cash' THEN 'paid_unfulfilled'
        WHEN f->>'state'='PENDING' AND f->>'paid_at' IS NULL AND f->>'completed_at' IS NULL THEN 'payment_pending'
        ELSE 'evidence_review' END;
    RETURN jsonb_build_object('cutoff',original,'sourceMarker',marker,'nativeOrder',p_order,'proofHash',encode(stored_hash,'hex'),
        'state',state,'basis',basis,'sourceBasis',source_basis,'originalState',f->>'state','orderType',f->>'order_type','hasOrderReferences',references_complete,
        'verifiedPayAmount',actual_paid::text,'paymentAudit',CASE WHEN actual_paid IS NOT NULL THEN paid_audit END,'hasFulfilmentAudit',credit_audit,
        'currency',f->>'currency_evidence','recordedPayAmount',f->>'order_pay_amount','recordedCreditUnits',f->>'credit_amount',
        'bonusUnits',f->>'bonus','reportedRefundUnits',f->>'reported_refund','forcedRefund',f->'forced_refund',
        'originalProvider',f->>'provider_key','originalProviderInstance',f->>'provider_instance','tradeRef',f->>'trade_ref','merchantOrderRef',f->>'merchant_ref',
        'paidAt',f->>'paid_at','completedAt',f->>'completed_at','refundRequestedAt',f->>'refund_requested_at','refundAt',f->>'refund_at','hasRefundAudit',refund_audit);
END $$;

-- S2 固定了审计行及内容摘要。只有仍与该摘要一致的原审计才可交出退款引用和旧预扣，缺字段保持未知。
CREATE FUNCTION meton_ledger.legacy_pending_deduction(expected text,raw text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE detail jsonb; deduction text:='unverified'; amount text; ref text;
BEGIN
    IF raw IS NULL OR octet_length(raw)>65536 OR meton_ledger.legacy_hash(raw) IS DISTINCT FROM expected THEN
        RETURN jsonb_build_object('state','unverified'); END IF;
    BEGIN detail:=raw::jsonb; EXCEPTION WHEN data_exception THEN RETURN jsonb_build_object('state','unverified'); END;
    IF jsonb_typeof(detail->'refundID')='string' AND detail->>'refundID' ~ '^[A-Za-z0-9_.:-]{1,128}$' THEN ref:=detail->>'refundID'; END IF;
    IF jsonb_typeof(detail->'balanceDeducted')='number' AND detail->>'balanceDeducted' ~ '^(0|[1-9][0-9]{0,18})([.][0-9]{1,8})?$' THEN
        amount:=detail->>'balanceDeducted'; END IF;
    IF detail->'deductionHeld'='true'::jsonb AND detail->>'deductionType'='balance' AND amount IS NOT NULL
        AND coalesce(detail->'deductionRollbackOK','false'::jsonb)='false'::jsonb THEN deduction:='held';
    ELSIF detail->'deductionRollbackOK'='true'::jsonb AND coalesce(detail->'deductionHeld','false'::jsonb)='false'::jsonb
        AND coalesce(detail->>'deductionType','balance')='balance' AND amount IS NOT NULL AND amount::numeric>0 THEN deduction:='returned'; END IF;
    RETURN jsonb_build_object('state',deduction,'balanceUnits',amount,'refundRef',ref,
        'deductionType',CASE WHEN detail->>'deductionType' IN ('balance','subscription','none') THEN detail->>'deductionType' END);
END $$;
CREATE FUNCTION meton_ledger.read_legacy_refund_audits(o jsonb,original uuid,p_order bigint,after_id bigint,page_size integer)
RETURNS TABLE(audit_id bigint,action text,evidence_hash text,original_deduction jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF (after_id>=0 AND page_size BETWEEN 1 AND 100) IS NOT TRUE THEN RAISE EXCEPTION 'invalid refund evidence page' USING ERRCODE='22023'; END IF;
    PERFORM meton_ledger.require_legacy_cash_cutoff(o,original);
    RETURN QUERY SELECT a.native_id,a.proof->>'action',a.proof->>'detail_digest',
        CASE WHEN a.proof->>'action'='REFUND_PENDING' THEN meton_ledger.legacy_pending_deduction(a.proof->>'detail_digest',l.detail) END
        FROM meton_ledger.legacy_cash_handoffs h JOIN meton_ledger.legacy_cash_facts a ON a.cutoff=h.cutoff
            AND a.kind='order_audit' AND a.proof->>'order_id'=h.native_order::text
        LEFT JOIN public.payment_audit_logs l ON l.id=a.native_id AND l.order_id=h.native_order::text AND l.action=a.proof->>'action'
        WHERE (h.cutoff,h.source_marker,h.native_order)=(original,(o->>'source_marker')::uuid,p_order)
          AND a.native_id>after_id AND a.proof->>'action' LIKE 'REFUND%' ORDER BY a.native_id LIMIT page_size;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.require_legacy_cash_cutoff(jsonb,uuid),meton_ledger.accept_legacy_cash_page(jsonb,uuid,bigint,integer),
    meton_ledger.read_legacy_cash_order(jsonb,uuid,bigint),meton_ledger.legacy_verified_payment(jsonb,text,text),meton_ledger.legacy_pending_deduction(text,text),
    meton_ledger.read_legacy_refund_audits(jsonb,uuid,bigint,bigint,integer) FROM PUBLIC;
