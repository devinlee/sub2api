-- 现金投影只读原事实。分页截点是内容身份，不创建新的来源快照、余额或执行权。
CREATE FUNCTION meton_ledger.cash_statement_fields(value jsonb,fields text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT coalesce(jsonb_object_agg(field,value->field),'{}'::jsonb) FROM unnest(fields) field WHERE value ? field
$$;

/** 公开材料按字段清单构造；历史原凭证、商户交易信息、内部签章和审核材料不能随投影下发。 */
CREATE FUNCTION meton_ledger.cash_statement_item(owner jsonb,item jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE kind text:=item->>'kind'; ref text:=item->>'ref'; v jsonb:=item->'value'; result jsonb;
BEGIN
    CASE kind
    WHEN 'source' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','kind','sequence','remaining','held','refundHeld','available','refundable']);
    WHEN 'registration' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','state','event','termination']);
    WHEN 'order' THEN
        result:=meton_ledger.cash_statement_fields(v,ARRAY['category','intent','closeState','closeVersion','cashReview']);
        SELECT result||jsonb_build_object('order',o.native_order,'currency',o.currency,'priceFen',o.price_fen::text,
            'unit',o.unit,'creditUnits',o.credit_units::text,'priceVersion',o.price_version,'createdAt',o.created_at,'expiresAt',o.expires_at)
            INTO result FROM meton_ledger.cash_orders o WHERE o.source_marker=(owner->>'source_marker')::uuid AND o.native_order::text=ref;
    WHEN 'payment' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','order','state','version','currency','payerFen','orderFen']);
    WHEN 'cash_basis' THEN
        result:=meton_ledger.cash_statement_fields(v,ARRAY['category','order','part','basis','payment','credit']);
        result:=result||jsonb_build_object('availability',v#>>'{snapshot,state}',
            'quote',meton_ledger.cash_statement_fields(v->'snapshot',ARRAY['state','currency','faceFen','paymentCapFen','partReturnedFen',
                'paymentReturnedFen','retiredUnits','originalUnits','availableUnits','creditEvent','lotVersion','refundCount','dispositionVersion']));
        SELECT result||jsonb_build_object('faceFen',p.basis_fen::text,'originalUnits',e.amount::text)
            INTO result FROM meton_ledger.cash_parts p LEFT JOIN meton_ledger.events e ON e.event_id=p.credit_event
            WHERE p.source_marker=(owner->>'source_marker')::uuid AND p.part_id::text=ref;
    WHEN 'legacy_order' THEN
        result:=meton_ledger.cash_statement_fields(v,ARRAY['category','cutoff','nativeOrder','state','basis','originalState','orderType',
            'hasOrderReferences','verifiedPayAmount','hasFulfilmentAudit','currency','recordedPayAmount','recordedCreditUnits','bonusUnits',
            'reportedRefundUnits','forcedRefund','paidAt','completedAt','refundRequestedAt','refundAt','hasRefundAudit']);
        result:=result||jsonb_build_object('sourceBasis',meton_ledger.cash_statement_fields(v->'sourceBasis',
            ARRAY['creditEvent','unit','denomination','ruleVersion','faceValue','conversionRate','originalUnits','openingUnits']));
    WHEN 'legacy_basis' THEN
        result:=meton_ledger.cash_statement_fields(v,ARRAY['category','order','cutoff','basis']);
        result:=result||jsonb_build_object('availability',v#>>'{snapshot,state}',
            'quote',meton_ledger.cash_statement_fields(v->'snapshot',ARRAY['state','currency','faceFen','paymentCapFen','partReturnedFen',
                'paymentReturnedFen','retiredUnits','originalUnits','availableUnits','creditEvent','lotVersion','refundCount']));
    WHEN 'legacy_activity' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','kind','original']);
    WHEN 'legacy_refund_audit' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','order','action','originalDeduction']);
    WHEN 'unmapped_order' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','state']);
    WHEN 'refund' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','order','part','cutoff','basis','phase','version','fen',
        'units','cashConfirmed','sourceSettled','recoveryConfirmed']);
    WHEN 'model' THEN result:=meton_ledger.cash_statement_fields(v,ARRAY['category','operation','sendState','quote','uncovered','execution','feeReady']);
    WHEN 'cash_review' THEN
        result:=meton_ledger.cash_statement_fields(v,ARRAY['category','refund','payment','cutoff','order','credit']);
        result:=result||jsonb_build_object('exposure',meton_ledger.cash_statement_fields(v->'exposure',ARRAY['currency','payerCapFen',
            'knownExternalFen','knownRefundFen','knownReturnedFen','knownExcessFen','externalEvents','ambiguousExternalEvents','ambiguousRefundEvents']));
    WHEN 'dispute' THEN
        result:=meton_ledger.cash_statement_fields(v,ARRAY['category','order','revision']);
        result:=result||jsonb_build_object('status',meton_ledger.cash_statement_fields(v->'value',ARRAY['state','revision','phase','outcome']));
    ELSE RAISE EXCEPTION 'cash statement category requires explicit projection' USING ERRCODE='55000';
    END CASE;
    IF result IS NULL OR result->>'category' IS NULL THEN RAISE EXCEPTION 'original cash statement item missing' USING ERRCODE='55000'; END IF;
    RETURN jsonb_build_object('kind',kind,'ref',ref,'value',result);
END $$;

/** 金额只分组核对原事实，不生成“现金可用余额”。历史与外部返还独立列出，不能与当次记录重复相加。 */
CREATE FUNCTION meton_ledger.cash_statement_totals(items jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE paid numeric; bought numeric; unposted numeric; confirmed numeric; settled numeric; pending numeric; cash_held numeric;
    historical bigint; unmapped bigint; external_reviews bigint; disputes bigint;
BEGIN
    SELECT coalesce(sum((x#>>'{value,payerFen}')::numeric) FILTER(WHERE x->>'kind'='payment'),0),
        coalesce(sum((x#>>'{value,faceFen}')::numeric) FILTER(WHERE x->>'kind'='cash_basis' AND x#>>'{value,basis}'='purchased_source'),0),
        coalesce(sum((x#>>'{value,faceFen}')::numeric) FILTER(WHERE x->>'kind'='cash_basis' AND x#>>'{value,basis}'='unposted_cash'),0),
        coalesce(sum((x#>>'{value,fen}')::numeric) FILTER(WHERE x->>'kind'='refund' AND x#>>'{value,cashConfirmed}'='true'),0),
        coalesce(sum((x#>>'{value,fen}')::numeric) FILTER(WHERE x->>'kind'='refund' AND x#>>'{value,sourceSettled}'='true'),0),
        coalesce(sum((x#>>'{value,fen}')::numeric) FILTER(WHERE x->>'kind'='refund' AND x#>>'{value,phase}' NOT IN ('released','settled')),0),
        coalesce(sum((x#>>'{value,fen}')::numeric) FILTER(WHERE x->>'kind'='refund' AND x#>>'{value,basis}'='unposted_cash'
            AND x#>>'{value,phase}' NOT IN ('released','settled')),0),
        count(*) FILTER(WHERE x->>'kind'='legacy_order'),count(*) FILTER(WHERE x->>'kind'='unmapped_order'),
        count(*) FILTER(WHERE x->>'kind'='cash_review'),count(*) FILTER(WHERE x->>'kind'='dispute')
        INTO paid,bought,unposted,confirmed,settled,pending,cash_held,historical,unmapped,external_reviews,disputes
        FROM jsonb_array_elements(items) x;
    IF paid<bought+unposted OR settled>confirmed OR cash_held>pending OR
        EXISTS(SELECT FROM unnest(ARRAY[paid,bought,unposted,confirmed,settled,pending,cash_held]) n WHERE n<0 OR n<>trunc(n)) THEN
        RAISE EXCEPTION 'original cash statement does not reconcile' USING ERRCODE='55000'; END IF;
    RETURN jsonb_build_object('scope','recorded_cash_facts','currency','CNY','paymentRecordedFen',paid::text,
        'purchaseAllocatedFen',bought::text,'unpostedAllocatedFen',unposted::text,'unallocatedFen',(paid-bought-unposted)::text,
        'refundConfirmedFen',confirmed::text,'refundSourceSettledFen',settled::text,'refundAwaitingSourceFen',(confirmed-settled)::text,
        'refundPendingFen',pending::text,'unpostedRefundPendingFen',cash_held::text,'historicalOrders',historical,
        'unmappedOrders',unmapped,'externalReviews',external_reviews,'disputes',disputes);
END $$;

/** 每页复验当前身份或原关闭范围，再在单条只读语句中复算内容截点。原序号不代表可变现金状态。 */
CREATE FUNCTION meton_ledger.read_cash_statement(o jsonb,audience jsonb,p_from date,p_through date,p_cut text,p_after bigint,p_size integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE m public.meton_managed_creations; f meton_ledger.cash_account_facts; s meton_ledger.cash_closure_scopes;
    inventory jsonb; statement jsonb; items jsonb; original_items jsonb; orders text[]; current_item jsonb; reply jsonb; details jsonb;
    header jsonb; cut text; count_items bigint; selected jsonb; next_item bigint; closure jsonb; ord text;
BEGIN
    IF current_setting('transaction_read_only')<>'on' OR current_setting('transaction_isolation')<>'read committed' THEN
        RAISE EXCEPTION 'cash statement requires current read-only transaction' USING ERRCODE='25006'; END IF;
    IF (jsonb_typeof(o)='object' AND o ?& ARRAY['environment','source','epoch','user','account','creation','dispatch','remote_user','source_marker','source_system']
        AND o-ARRAY['environment','source','epoch','user','account','creation','dispatch','remote_user','source_marker','source_system']='{}'::jsonb) IS NOT TRUE THEN
        RAISE EXCEPTION 'exact original statement owner required' USING ERRCODE='22023'; END IF;
    PERFORM meton_ledger.require_refund_owner(o);
    m:=meton_ledger.statement_owner(o->>'environment',o->>'source',(o->>'epoch')::bigint,(o->>'user')::uuid,
        (o->>'account')::uuid,(o->>'creation')::uuid,(o->>'dispatch')::uuid,(o->>'remote_user')::bigint,(o->>'source_marker')::uuid);
    PERFORM meton_ledger.statement_window(p_from,p_through);
    IF p_after IS NULL OR p_after<0 OR p_size IS NULL OR p_size NOT BETWEEN 1 AND 100 OR
        p_cut IS NULL AND p_after<>0 OR p_cut IS NOT NULL AND p_cut!~'^[a-f0-9]{64}$' THEN
        RAISE EXCEPTION 'bounded original cash statement cursor required' USING ERRCODE='22023'; END IF;
    SELECT * INTO f FROM meton_ledger.cash_account_facts WHERE source_marker=m.source_marker
        AND (registration,user_id,account_id,creation,projection_epoch)=
            ((audience->>'registration')::uuid,m.meton_user,m.account,m.operation,m.epoch);
    IF NOT FOUND THEN RAISE EXCEPTION 'current cash statement identity missing' USING ERRCODE='42501'; END IF;
    IF audience->>'kind'='account' THEN
        IF audience-ARRAY['kind','registration','identity']<>'{}'::jsonb OR audience->'identity' IS DISTINCT FROM
            jsonb_build_object('lifecycle','active','securityVersion',f.security_version,'recoveryVersion',f.recovery_version,'lastStopVersion',f.last_stop_version)
            OR f.lifecycle<>'active' OR NOT EXISTS(SELECT FROM public.users WHERE id=m.remote_user AND status='active') THEN
            RAISE EXCEPTION 'current account statement identity changed' USING ERRCODE='42501'; END IF;
    ELSIF audience->>'kind'='aftercare' THEN
        IF audience-ARRAY['kind','registration','closure','scope']<>'{}'::jsonb OR f.lifecycle<>'closed' THEN
            RAISE EXCEPTION 'original closed statement identity required' USING ERRCODE='42501'; END IF;
        SELECT scope.* INTO s FROM meton_ledger.cash_closure_scopes scope JOIN meton_ledger.cash_closure_final_facts final USING(closure_id)
            WHERE scope.closure_id=(audience->>'closure')::uuid AND scope.owner=o AND scope.registration=f.registration
                AND scope.receipt->>'scopeHash'=audience->>'scope';
        IF NOT FOUND THEN RAISE EXCEPTION 'original aftercare statement range missing' USING ERRCODE='42501'; END IF;
        SELECT snap.items INTO STRICT original_items FROM meton_ledger.cash_closure_snapshots snap WHERE snap.snapshot_id=s.snapshot_id;
        SELECT coalesce(array_agg(CASE x->>'kind' WHEN 'order' THEN x->>'ref' ELSE x#>>'{value,nativeOrder}' END),'{}'::text[])
            INTO orders FROM jsonb_array_elements(original_items) x WHERE x->>'kind' IN ('order','legacy_order');
        closure:=jsonb_build_object('operation',s.closure_id,'state','closed','funds','aftercare_open','scope',audience->>'scope');
    ELSE RAISE EXCEPTION 'explicit cash statement audience required' USING ERRCODE='22023'; END IF;
    inventory:=meton_ledger.cash_closure_inventory(o);
    IF audience->>'kind'='account' THEN
        statement:=meton_ledger.open_statement(o->>'environment',o->>'source',(o->>'epoch')::bigint,m.meton_user,
            m.account,m.operation,m.dispatch,m.remote_user,m.source_marker,p_from,p_through);
    END IF;
    items:='[]'::jsonb;
    FOR current_item IN SELECT x FROM jsonb_array_elements(inventory->'items') x LOOP
        IF audience->>'kind'='aftercare' THEN
            ord:=current_item#>>'{value,order}';
            IF (EXISTS(SELECT FROM jsonb_array_elements(original_items) x
                WHERE (x->>'kind',x->>'ref')=(current_item->>'kind',current_item->>'ref')) OR
                current_item->>'kind' IN ('payment','cash_basis','refund','legacy_basis','legacy_refund_audit','cash_review','dispute') AND ord=ANY(orders)) IS NOT TRUE THEN
                CONTINUE;
            END IF;
        END IF;
        details:=meton_ledger.cash_statement_item(o,current_item);
        items:=items||jsonb_build_array(details||jsonb_build_object('ordinal',jsonb_array_length(items)+1));
    END LOOP;
    count_items:=jsonb_array_length(items);
    -- 原归属与用途进入截点；观察时间不作为内容身份，H/R 与实际现金分类则必须全部在内。
    header:=jsonb_build_object('format',1,'origin',o,'audience',audience,'from',p_from,'through',p_through,
        'ledger',CASE WHEN statement IS NULL THEN NULL ELSE jsonb_set(statement,'{cut}',(statement->'cut')-'observed_at') END,
        'cash',meton_ledger.cash_statement_totals(items),'closure',closure,'count',count_items);
    cut:=encode(sha256(convert_to(jsonb_build_object('header',header,'items',items)::text,'UTF8')),'hex');
    IF p_cut IS NOT NULL AND p_cut<>cut THEN
        RETURN jsonb_build_object('format',1,'state','snapshot_changed','origin',o,'audience',audience); END IF;
    IF p_after>count_items THEN RAISE EXCEPTION 'cash statement cursor beyond original inventory' USING ERRCODE='22023'; END IF;
    SELECT coalesce(jsonb_agg(x ORDER BY (x->>'ordinal')::bigint),'[]'::jsonb) INTO selected FROM jsonb_array_elements(items) x
        WHERE (x->>'ordinal')::bigint>p_after AND (x->>'ordinal')::bigint<=p_after+p_size;
    next_item:=p_after+jsonb_array_length(selected);
    reply:=header||jsonb_build_object('state','observed','cut',cut,'observedAt',statement_timestamp(),'ledger',statement,
        'after',p_after,'size',p_size,'next',next_item,'more',next_item<count_items,'items',selected);
    IF octet_length(reply::text)>196608 THEN RAISE EXCEPTION 'cash statement page exceeds bounded response' USING ERRCODE='54000'; END IF;
    RETURN reply;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.cash_statement_fields(jsonb,text[]),meton_ledger.cash_statement_item(jsonb,jsonb),
    meton_ledger.cash_statement_totals(jsonb),meton_ledger.read_cash_statement(jsonb,jsonb,date,date,text,bigint,integer) FROM PUBLIC;
