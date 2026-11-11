-- 来源重放仍经过 306 的原注册和单调序号。兼容 Identity 保留的安全停用状态，解除只开放新代次订单。
DO $restrictions$
DECLARE observe_def text:=pg_get_functiondef('meton_ledger.observe_cash_lifecycle(jsonb,uuid,jsonb,timestamptz)'::regprocedure);
    record_def text:=pg_get_functiondef('meton_ledger.record_cash_account_fact(text,text,bigint,jsonb,uuid,bigint,bigint,bigint,text,timestamptz)'::regprocedure);
    states constant text:='''active'',''closing'',''security_recovery'',''closed''';
    stopped constant text:='fact->>''lifecycle'' IN (''closing'',''closed'')';
    reopen constant text:='earlier.lifecycle=''security_recovery'' AND lifecycle=''active''';
BEGIN
    IF cardinality(string_to_array(observe_def,states))<>2 OR cardinality(string_to_array(observe_def,stopped))<>2
        OR cardinality(string_to_array(record_def,reopen))<>2 THEN RAISE EXCEPTION 'cash lifecycle definition changed'; END IF;
    EXECUTE replace(replace(observe_def,states,states||',''disabled'''),stopped,'fact->>''lifecycle'' IN (''closing'',''closed'',''disabled'')');
    EXECUTE replace(record_def,reopen,reopen||' OR earlier.lifecycle=''disabled'' AND lifecycle IN (''active'',''security_recovery'')');
END $restrictions$;
