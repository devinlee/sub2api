-- 来源恢复到结清之前，截点外队列可能早已签收。每个当前签名版本按原路由有界重读一次，仍只允许投递同一份现金凭证。
ALTER TABLE meton_inbox.refund_settlement_work ADD COLUMN authority_epoch bigint, ADD COLUMN authority_key uuid,
    ADD CHECK((authority_epoch IS NULL)=(authority_key IS NULL));
CREATE INDEX refund_wire_settlement_route ON meton_inbox.refund_wire_bindings
    ((envelope#>>'{scope,deployment}'),(envelope#>>'{scope,source}'),channel,cash_environment,merchant,(envelope#>>'{scope,app}'),refund);
CREATE TABLE meton_inbox.refund_settlement_rechecks(
    deployment text NOT NULL,source text NOT NULL,epoch bigint NOT NULL,key_ref uuid NOT NULL,
    channel text NOT NULL,cash_environment text NOT NULL,merchant text NOT NULL,app text NOT NULL,
    through_ref uuid, cursor_ref uuid, finished boolean NOT NULL,
    PRIMARY KEY(deployment,source,epoch,key_ref,channel,cash_environment,merchant,app),
    CHECK(cursor_ref IS NULL OR cursor_ref<=through_ref)
);
REVOKE ALL ON meton_inbox.refund_settlement_rechecks FROM PUBLIC;

CREATE FUNCTION meton_inbox.recheck_original_refund_work(route jsonb,a meton_inbox.refund_gate_authorities) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE cut meton_inbox.refund_settlement_rechecks; high uuid; seen uuid; chunk uuid[];
BEGIN
    SELECT * INTO cut FROM meton_inbox.refund_settlement_rechecks c WHERE (c.deployment,c.source,c.epoch,c.key_ref,c.channel,c.cash_environment,c.merchant,c.app)=
        (a.deployment,a.source,a.epoch,a.key_ref,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app');
    IF cut.finished THEN RETURN; END IF;
    IF cut.key_ref IS NULL THEN
        SELECT b.refund INTO high FROM meton_inbox.refund_wire_bindings b WHERE
            (b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}',b.channel,b.cash_environment,b.merchant,b.envelope#>>'{scope,app}')=
            (a.deployment,a.source,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') ORDER BY b.refund DESC LIMIT 1;
        INSERT INTO meton_inbox.refund_settlement_rechecks VALUES(a.deployment,a.source,a.epoch,a.key_ref,route->>'channel',route->>'cashEnvironment',
            route->>'merchant',route->>'app',high,NULL,high IS NULL) ON CONFLICT DO NOTHING;
    END IF;
    SELECT * INTO cut FROM meton_inbox.refund_settlement_rechecks c WHERE (c.deployment,c.source,c.epoch,c.key_ref,c.channel,c.cash_environment,c.merchant,c.app)=
        (a.deployment,a.source,a.epoch,a.key_ref,route->>'channel',route->>'cashEnvironment',route->>'merchant',route->>'app') AND NOT c.finished FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT array_agg(batch.refund ORDER BY batch.refund) INTO chunk FROM (
        SELECT b.refund FROM meton_inbox.refund_wire_bindings b WHERE
            (b.envelope#>>'{scope,deployment}',b.envelope#>>'{scope,source}',b.channel,b.cash_environment,b.merchant,b.envelope#>>'{scope,app}')=
            (a.deployment,a.source,cut.channel,cut.cash_environment,cut.merchant,cut.app)
            AND (cut.cursor_ref IS NULL OR b.refund>cut.cursor_ref) AND b.refund<=cut.through_ref ORDER BY b.refund LIMIT 32) batch;
    IF chunk IS NOT NULL THEN
        seen:=chunk[cardinality(chunk)];
        -- 同版本已处理的工作不再唤醒。新绑定或迟到通知由入库触发器投递，不依赖这段游标。
        UPDATE meton_inbox.refund_settlement_work w SET token=NULL,revision=w.revision+1,next_at=clock_timestamp(),last_state='ready'
            WHERE w.refund=ANY(chunk) AND (w.authority_epoch,w.authority_key) IS DISTINCT FROM (a.epoch,a.key_ref);
    END IF;
    UPDATE meton_inbox.refund_settlement_rechecks c SET cursor_ref=coalesce(seen,cut.cursor_ref),finished=seen IS NULL OR seen=cut.through_ref
        WHERE (c.deployment,c.source,c.epoch,c.key_ref,c.channel,c.cash_environment,c.merchant,c.app)=
            (a.deployment,a.source,a.epoch,a.key_ref,cut.channel,cut.cash_environment,cut.merchant,cut.app);
END $$;
REVOKE ALL ON FUNCTION meton_inbox.recheck_original_refund_work(jsonb,meton_inbox.refund_gate_authorities) FROM PUBLIC;
DO $dispatch$
DECLARE body text:=pg_get_functiondef('meton_inbox.claim_refund_settlement(jsonb)'::regprocedure);
    before_select constant text:='SELECT j.* INTO job FROM meton_inbox.refund_settlement_work j';
    stamp constant text:='SET token=gen_random_uuid(),next_at=';
BEGIN
    IF cardinality(string_to_array(body,before_select))<>2 OR cardinality(string_to_array(body,stamp))<>2 THEN RAISE EXCEPTION 'original settlement claim changed'; END IF;
    body:=replace(body,before_select,'PERFORM meton_inbox.recheck_original_refund_work(route,a); '||before_select);
    EXECUTE replace(body,stamp,'SET authority_epoch=a.epoch,authority_key=a.key_ref,token=gen_random_uuid(),next_at=');
END $dispatch$;
