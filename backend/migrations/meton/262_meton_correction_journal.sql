-- 执行回执与资金事件要双向匹配。恢复旧数据时，只有外键指向某一笔流水仍不足以证明原额度真的返还。
CREATE FUNCTION meton_ledger.correction_amount(p_lines jsonb)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT sum((value->>'amount')::numeric) FROM jsonb_array_elements(p_lines)
$$;
ALTER TABLE meton_ledger.text_correction_decisions ADD CONSTRAINT original_correction_lines CHECK(
    sources=meton_ledger.correction_sources(sources) AND amount=meton_ledger.correction_amount(sources));

CREATE FUNCTION meton_ledger.correction_has_journal(p_decision uuid,p_journal uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT EXISTS (SELECT FROM meton_ledger.text_correction_decisions d JOIN meton_ledger.text_requests r USING(request_id)
        JOIN meton_ledger.events e ON e.event_id=p_journal AND e.source_marker=r.source_marker AND e.environment=r.environment AND e.source=r.source
        WHERE d.decision=p_decision AND e.kind='text_correction' AND e.origin_ref=d.decision AND e.operation_id=d.decision AND e.amount=d.amount)
$$;
DO $migration$
BEGIN
    IF EXISTS (SELECT FROM meton_ledger.text_corrections x WHERE NOT meton_ledger.correction_has_journal(x.decision,x.journal)) THEN
        RAISE EXCEPTION 'existing correction has no matching original money event' USING ERRCODE='23514';
    END IF;
END $migration$;
CREATE FUNCTION meton_ledger.check_correction_journal() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NOT meton_ledger.correction_has_journal(NEW.decision,NEW.journal) THEN
        RAISE EXCEPTION 'correction has no matching original money event' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER original_correction_journal AFTER INSERT ON meton_ledger.text_corrections DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_correction_journal();
REVOKE ALL ON FUNCTION meton_ledger.correction_amount(jsonb),meton_ledger.correction_has_journal(uuid,uuid),meton_ledger.check_correction_journal() FROM PUBLIC;
