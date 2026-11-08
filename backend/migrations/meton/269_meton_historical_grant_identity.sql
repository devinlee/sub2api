-- 历史领取／终止与新兑换共享原资格身份。发现已有冲突时保留两侧原事实并停止升级，不能清零或再补一笔。
DO $preflight$
BEGIN
    IF EXISTS(SELECT FROM meton_ledger.legacy_qualifications q JOIN meton_ledger.registration_grants g USING(eligibility)) THEN
        RAISE EXCEPTION 'historical qualification conflicts with a source grant' USING ERRCODE='23514'; END IF;
END $preflight$;

CREATE FUNCTION meton_ledger.check_historical_grant_identity() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    -- 沿用原内部业务码锁，并更新已有原生引用版本；仅 advisory lock 无法使可重复读的旧快照看到另一张表的提交。
    PERFORM pg_advisory_xact_lock(hashtextextended(replace(NEW.eligibility::text,'-',''),256));
    PERFORM meton_ledger.lock_native_references(ARRAY['meton-qualification:'||NEW.eligibility::text]);
    IF (TG_TABLE_NAME='legacy_qualifications' AND EXISTS(SELECT FROM meton_ledger.registration_grants WHERE eligibility=NEW.eligibility)) OR
       (TG_TABLE_NAME='registration_grants' AND EXISTS(SELECT FROM meton_ledger.legacy_qualifications WHERE eligibility=NEW.eligibility)) THEN
        RAISE EXCEPTION 'original qualification already received or terminated' USING ERRCODE='23505'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER meton_original_qualification BEFORE INSERT ON meton_ledger.legacy_qualifications
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_historical_grant_identity();
CREATE TRIGGER meton_original_qualification BEFORE INSERT ON meton_ledger.registration_grants
    FOR EACH ROW EXECUTE FUNCTION meton_ledger.check_historical_grant_identity();
ALTER TABLE meton_ledger.legacy_qualifications ENABLE ALWAYS TRIGGER meton_original_qualification;
ALTER TABLE meton_ledger.registration_grants ENABLE ALWAYS TRIGGER meton_original_qualification;

CREATE FUNCTION meton_ledger.historical_qualification_guards_ready() RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT NOT EXISTS(SELECT FROM (VALUES('meton_ledger.legacy_qualifications'::regclass),('meton_ledger.registration_grants'::regclass)) expected(tbl)
        WHERE NOT EXISTS(SELECT FROM pg_trigger t WHERE t.tgrelid=expected.tbl AND t.tgname='meton_original_qualification'
            AND t.tgfoid='meton_ledger.check_historical_grant_identity()'::regprocedure AND t.tgenabled='A' AND t.tgtype=7
            AND NOT t.tgdeferrable AND NOT t.tginitdeferred AND t.tgqual IS NULL AND t.tgnargs=0 AND t.tgattr=''::int2vector))
$$;

DO $guard$
DECLARE definition text; needle text;
BEGIN
    definition:=pg_get_functiondef('meton_ledger.redeem_registration(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,text,text)'::regprocedure);
    needle:='PERFORM pg_advisory_xact_lock(hashtextextended(original_code,256));';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected registration qualification boundary'; END IF;
    EXECUTE replace(definition,needle,$ready$IF NOT meton_ledger.historical_qualification_guards_ready() THEN
        RAISE EXCEPTION 'qualification protection unavailable' USING ERRCODE='55000'; END IF;
    $ready$||needle);
    definition:=pg_get_functiondef('meton_ledger.record_legacy_source_review(text,text,bigint,uuid,uuid,uuid,uuid,bigint,uuid,uuid,uuid,uuid,text,text,jsonb,jsonb,text)'::regprocedure);
    needle:='SELECT * INTO prior FROM meton_ledger.legacy_source_reviews';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected history qualification boundary'; END IF;
    EXECUTE replace(definition,needle,$ready$IF NOT meton_ledger.historical_qualification_guards_ready() THEN
        RAISE EXCEPTION 'qualification protection unavailable' USING ERRCODE='55000'; END IF;
    $ready$||needle);
    definition:=pg_get_functiondef('meton_ledger.legacy_opening_guards_ready()'::regprocedure);
    needle:='SELECT NOT EXISTS';
    IF cardinality(string_to_array(definition,needle))<>2 THEN RAISE EXCEPTION 'unexpected source opening readiness'; END IF;
    EXECUTE replace(definition,needle,'SELECT meton_ledger.historical_qualification_guards_ready() AND NOT EXISTS');
END $guard$;
REVOKE ALL ON FUNCTION meton_ledger.check_historical_grant_identity(),meton_ledger.historical_qualification_guards_ready() FROM PUBLIC;
