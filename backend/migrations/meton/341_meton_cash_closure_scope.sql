-- 原资金清单只在当前本人确认窗口内绑定到一个注销申请。此记录本身不授权退款、核销或关闭账号。
CREATE TABLE meton_ledger.cash_closure_scope_roles(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL CHECK(epoch>0),
    actor name PRIMARY KEY,purpose text NOT NULL CHECK(purpose IN ('bind','read'))
);
CREATE TABLE meton_ledger.cash_closure_scopes(
    closure_id uuid PRIMARY KEY CHECK(closure_id<>'00000000-0000-0000-0000-000000000000'),
    snapshot_id uuid NOT NULL UNIQUE REFERENCES meton_ledger.cash_closure_snapshots(snapshot_id),
    owner jsonb NOT NULL,registration uuid NOT NULL,identity_fact jsonb NOT NULL,
    inspection_hash text NOT NULL CHECK(inspection_hash~'^[0-9a-f]{64}$'),
    confirmation_hash text NOT NULL CHECK(confirmation_hash~'^[0-9a-f]{64}$'),
    bound_at timestamptz NOT NULL CHECK(isfinite(bound_at)),receipt jsonb NOT NULL
);
DO $protect$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['cash_closure_scope_roles','cash_closure_scopes'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_fact BEFORE UPDATE OR DELETE ON meton_ledger.%I FOR EACH ROW EXECUTE FUNCTION meton_ledger.keep_event()',t);
        EXECUTE format('ALTER TABLE meton_ledger.%I ENABLE ALWAYS TRIGGER immutable_fact',t);
        EXECUTE format('REVOKE ALL ON meton_ledger.%I FROM PUBLIC',t);
    END LOOP;
END $protect$;

/** 权限固定到当前来源代次和单一用途；知道旧原号不使旧节点恢复任何读写资格。 */
CREATE FUNCTION meton_ledger.require_cash_closure_scope_actor(o jsonb,action text) RETURNS void
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF current_setting('transaction_isolation')<>'read committed' OR NOT EXISTS(
        SELECT FROM meton_ledger.cash_closure_scope_roles r WHERE
            (r.deployment,r.source,r.epoch,r.actor,r.purpose)=
            (o->>'environment',o->>'source',(o->>'epoch')::bigint,session_user::name,action)) THEN
        RAISE EXCEPTION 'current closure scope authority required' USING ERRCODE='42501'; END IF;
    PERFORM meton_ledger.require_refund_owner(o);
END $$;

/** Identity 先以原申请暂停新准入，再在同一本人决定中固定用户看过的清单。丢回执只能查询这一原记录。 */
CREATE FUNCTION meton_ledger.bind_cash_closure_scope(o jsonb,closure uuid,inspection uuid,registration_id uuid,
    identity_state jsonb,inventory_hash text,confirmation_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE saved meton_ledger.cash_closure_snapshots; previous meton_ledger.cash_closure_scopes;
    current_inventory jsonb; definition jsonb; result jsonb; now_at timestamptz;
BEGIN
    PERFORM meton_ledger.require_cash_closure_scope_actor(o,'bind');
    PERFORM pg_advisory_xact_lock_shared(meton_ledger.cash_account_lock((o->>'source_marker')::uuid));
    -- 等待用户限制锁后重新复验，不能沿等待前的 active 身份或另一笔注销暂停继续。
    PERFORM meton_ledger.require_cash_closure_reader(o,registration_id,identity_state);
    IF closure IS NULL OR closure='00000000-0000-0000-0000-000000000000' OR inspection IS NULL OR
        (inventory_hash~'^[0-9a-f]{64}$' AND confirmation_hash~'^[0-9a-f]{64}$') IS NOT TRUE THEN
        RAISE EXCEPTION 'original closure confirmation required' USING ERRCODE='22023'; END IF;
    IF NOT EXISTS(SELECT FROM meton_ledger.cash_account_facts f WHERE
        (f.source_marker,f.registration,f.projection_epoch,f.preparing_closure)=
        ((o->>'source_marker')::uuid,registration_id,(o->>'epoch')::bigint,closure)) THEN
        RAISE EXCEPTION 'original closure admission must be paused' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('cash-closure-scope/'||closure::text,0));
    SELECT * INTO previous FROM meton_ledger.cash_closure_scopes WHERE closure_id=closure;
    IF FOUND THEN
        IF previous.owner IS DISTINCT FROM o OR previous.registration IS DISTINCT FROM registration_id THEN
            RAISE EXCEPTION 'unknown original closure scope' USING ERRCODE='42501'; END IF;
        IF (previous.snapshot_id,previous.identity_fact,previous.inspection_hash,previous.confirmation_hash) IS DISTINCT FROM
            (inspection,identity_state,inventory_hash,confirmation_hash) THEN
            RAISE EXCEPTION 'original closure confirmation differs' USING ERRCODE='23505'; END IF;
        RETURN previous.receipt;
    END IF;
    SELECT * INTO saved FROM meton_ledger.cash_closure_snapshots WHERE snapshot_id=inspection AND owner=o
        AND registration=registration_id AND identity_fact=identity_state;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown original closure inspection' USING ERRCODE='42501'; END IF;
    IF saved.header->>'inventoryHash' IS DISTINCT FROM inventory_hash THEN
        RAISE EXCEPTION 'inspected cash scope differs' USING ERRCODE='23505'; END IF;
    IF saved.expires_at<=clock_timestamp() THEN
        RETURN jsonb_build_object('state','expired','closure',closure,'inspection',inspection); END IF;
    IF EXISTS(SELECT FROM meton_ledger.cash_closure_scopes WHERE snapshot_id=inspection) THEN
        RAISE EXCEPTION 'inspection already belongs to an original closure' USING ERRCODE='23505'; END IF;
    current_inventory:=meton_ledger.cash_closure_inventory(o);
    -- 不把检查后出现的订单、占用或现金自动加入确认范围，也不把后来的余额套入原清单。
    IF current_inventory->>'inventoryHash' IS DISTINCT FROM inventory_hash OR
        current_inventory->'funds' IS DISTINCT FROM saved.header->'funds' THEN
        RETURN jsonb_build_object('state','scope_changed','closure',closure,'inspection',inspection); END IF;
    now_at:=clock_timestamp();
    IF saved.expires_at<=now_at THEN RETURN jsonb_build_object('state','expired','closure',closure,'inspection',inspection); END IF;
    definition:=jsonb_build_object('format',1,'purpose','cash_closure_scope','closure',closure,'inspection',inspection,
        'origin',o,'registration',registration_id,'identity',identity_state,'inventoryHash',inventory_hash,
        'confirmationHash',confirmation_hash,'count',saved.header->'count','cut',saved.header->'cut','inspectionExpiresAt',saved.expires_at);
    result:=definition||jsonb_build_object('state','bound','boundAt',now_at,
        'scopeHash',encode(sha256(convert_to(definition::text,'UTF8')),'hex'),'meaning','scope_only_identity_commit_and_execution_recheck_required');
    INSERT INTO meton_ledger.cash_closure_scopes VALUES(closure,inspection,o,registration_id,identity_state,inventory_hash,confirmation_hash,now_at,result);
    RETURN result;
END $$;

/** 原回执可以在检查到期或账号进入关闭后查询，但不恢复登录、不扩大原范围，也不授权执行资金动作。 */
CREATE FUNCTION meton_ledger.read_cash_closure_scope(o jsonb,closure uuid,registration_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE original meton_ledger.cash_closure_scopes;
BEGIN
    PERFORM meton_ledger.require_cash_closure_scope_actor(o,'read');
    SELECT * INTO original FROM meton_ledger.cash_closure_scopes WHERE closure_id=closure AND owner=o AND registration=registration_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN original.receipt;
END $$;
REVOKE ALL ON FUNCTION meton_ledger.require_cash_closure_scope_actor(jsonb,text),
    meton_ledger.bind_cash_closure_scope(jsonb,uuid,uuid,uuid,jsonb,text,text),
    meton_ledger.read_cash_closure_scope(jsonb,uuid,uuid) FROM PUBLIC;
