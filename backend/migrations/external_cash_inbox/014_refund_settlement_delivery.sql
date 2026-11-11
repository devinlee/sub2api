-- 每张原退款有一项可重领的结清工作。队列仅作投递，是否已退及是否存在争议仍由独立现金事实决定。
CREATE TABLE meton_inbox.refund_settlement_work(
    refund uuid PRIMARY KEY REFERENCES meton_inbox.refund_wire_bindings, revision bigint NOT NULL CHECK(revision>0),
    token uuid, next_at timestamptz NOT NULL, last_state text NOT NULL
);
CREATE INDEX refund_settlement_due ON meton_inbox.refund_settlement_work(next_at,refund);
CREATE INDEX refund_terminal_original_number ON meton_inbox.refund_terminal_facts(channel,cash_environment,merchant,(outcome->>'refundOrder'));
REVOKE ALL ON meton_inbox.refund_settlement_work FROM PUBLIC;

CREATE FUNCTION meton_inbox.wake_refund_settlement(ref uuid) RETURNS void LANGUAGE sql SET search_path=pg_catalog,pg_temp AS $$
    INSERT INTO meton_inbox.refund_settlement_work AS job(refund,revision,next_at,last_state)
        VALUES(ref,1,clock_timestamp(),'ready') ON CONFLICT(refund) DO UPDATE SET revision=job.revision+1,next_at=excluded.next_at,token=NULL,last_state='ready'
$$;
CREATE FUNCTION meton_inbox.schedule_refund_settlement() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE ref uuid;
BEGIN
    IF TG_TABLE_NAME='refund_terminal_facts' THEN
        SELECT b.refund INTO ref FROM meton_inbox.refund_wire_bindings b
            WHERE (b.channel,b.cash_environment,b.merchant,b.refund_number)=(NEW.channel,NEW.cash_environment,NEW.merchant,NEW.outcome->>'refundOrder');
        IF ref IS NULL THEN RETURN NEW; END IF;
    ELSE ref:=NEW.refund; END IF;
    PERFORM meton_inbox.wake_refund_settlement(ref);
    RETURN NEW;
END $$;
DO $install$ DECLARE n text; BEGIN
    FOREACH n IN ARRAY ARRAY['refund_wire_bindings','refund_wire_observations','refund_terminal_facts','refund_cash_disputes'] LOOP
        EXECUTE format('CREATE TRIGGER refund_settlement_arrived AFTER INSERT ON meton_inbox.%I FOR EACH ROW EXECUTE FUNCTION meton_inbox.schedule_refund_settlement()',n);
        EXECUTE format('ALTER TABLE meton_inbox.%I ENABLE ALWAYS TRIGGER refund_settlement_arrived',n);
    END LOOP;
END $install$;
INSERT INTO meton_inbox.refund_settlement_work(refund,revision,next_at,last_state)
    SELECT refund,1,clock_timestamp(),'ready' FROM meton_inbox.refund_wire_bindings;

CREATE FUNCTION meton_inbox.claim_refund_settlement(route jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route); job meton_inbox.refund_settlement_work;
BEGIN
    SELECT j.* INTO job FROM meton_inbox.refund_settlement_work j JOIN meton_inbox.refund_wire_bindings b USING(refund)
        WHERE j.next_at<=clock_timestamp() AND (b.channel,b.cash_environment,b.merchant,b.envelope#>>'{scope,app}',b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}')
            =(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',a.deployment,a.source)
        ORDER BY j.next_at,j.refund LIMIT 1 FOR UPDATE OF j SKIP LOCKED;
    IF NOT FOUND THEN RETURN NULL; END IF;
    UPDATE meton_inbox.refund_settlement_work SET token=gen_random_uuid(),next_at=clock_timestamp()+interval '20 seconds',last_state='working'
        WHERE refund=job.refund RETURNING * INTO job;
    RETURN jsonb_build_object('refund',job.refund,'revision',job.revision,'token',job.token);
END $$;
CREATE FUNCTION meton_inbox.finish_refund_settlement(route jsonb,ref uuid,rev bigint,lease uuid,result text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE a meton_inbox.refund_gate_authorities:=meton_inbox.require_refund_resolver(route);
BEGIN
    IF result IS NULL OR result NOT IN ('settled','review','retry','pending','closed_observed','original_unavailable','recovery_review') THEN
        RAISE EXCEPTION 'invalid original settlement outcome' USING ERRCODE='22023'; END IF;
    UPDATE meton_inbox.refund_settlement_work j SET token=NULL,last_state=result,next_at=CASE WHEN result IN ('settled','review','closed_observed') THEN 'infinity'::timestamptz
        WHEN result IN ('original_unavailable','recovery_review','pending') THEN clock_timestamp()+interval '45 seconds' ELSE clock_timestamp()+interval '3 seconds' END
        FROM meton_inbox.refund_wire_bindings b WHERE (j.refund,j.revision,j.token,j.last_state)=(ref,rev,lease,'working') AND b.refund=j.refund
        AND (b.channel,b.cash_environment,b.merchant,b.envelope#>>'{scope,app}',b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}')
            =(route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app',a.deployment,a.source);
    RETURN FOUND;
END $$;

REVOKE ALL ON FUNCTION meton_inbox.wake_refund_settlement(uuid),meton_inbox.schedule_refund_settlement(),
    meton_inbox.claim_refund_settlement(jsonb),meton_inbox.finish_refund_settlement(jsonb,uuid,bigint,uuid,text) FROM PUBLIC;

CREATE FUNCTION meton_inbox.refund_settlement_ready(route jsonb) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    PERFORM meton_inbox.require_refund_resolver(route);
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION meton_inbox.refund_settlement_ready(jsonb) FROM PUBLIC;
