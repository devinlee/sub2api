//go:build meton_managed && restored_resolution_integration

package metonledger

import (
    "context"
    "crypto/sha256"
    "crypto/x509"
    "database/sql"
    "encoding/hex"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "os"
    "reflect"
    "strconv"
    "strings"
    "sync/atomic"
    "testing"
    "time"

    "github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
    "github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
    "github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
    "github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
    "github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
    "github.com/google/uuid"
    _ "github.com/lib/pq"
)

/** 仅在本轮空库整体恢复所有托管主体，原会话先终结；不代表生产开放或归档恢复完成。 */
func restoredResultAdvance(t *testing.T,db *sql.DB,from,to int64) int {
    t.Helper()
    type session struct{env,source string;raw []byte}
    var sessions []session
    rows,err:=db.Query("SELECT DISTINCT ON(x.source_marker,x.session_id) a.environment,a.source,x.claim FROM meton_managed_keys x JOIN meton_managed_creations a USING(source_marker) WHERE NOT EXISTS(SELECT FROM meton_managed_session_closures c WHERE c.source_marker=x.source_marker AND c.session_id=x.session_id) ORDER BY x.source_marker,x.session_id")
    if err!=nil{t.Fatal(err)}
    for rows.Next(){var s session;if err=rows.Scan(&s.env,&s.source,&s.raw);err!=nil{t.Fatal(err)};sessions=append(sessions,s)}
    if err=rows.Err();err!=nil{t.Fatal(err)};_ =rows.Close()
    for _,s:=range sessions{
        var claim map[string]json.RawMessage
        if json.Unmarshal(s.raw,&claim)!=nil{t.Fatal("原会话材料损坏")}
        request:=map[string]any{"operation":uuid.NewString()}
        for _,key:=range []string{"origin","remoteUser","sourceMarker","session"}{request[key]=claim[key]}
        raw,_:=json.Marshal(request)
        if _,err=db.Exec("SELECT public.meton_close_original_session($1,$2,$3,$4,clock_timestamp()+interval '25 seconds')",s.env,s.source,from,string(raw));err!=nil{t.Fatal(err)}
    }
    type member struct{env,source,user,account,creation,dispatch,marker string;remote,epoch int64}
    var members []member
    rows,err=db.Query("SELECT environment,source,meton_user,account,operation,dispatch,source_marker,remote_user,epoch FROM meton_managed_creations ORDER BY source_marker")
    if err!=nil{t.Fatal(err)}
    for rows.Next(){var m member;if err=rows.Scan(&m.env,&m.source,&m.user,&m.account,&m.creation,&m.dispatch,&m.marker,&m.remote,&m.epoch);err!=nil{t.Fatal(err)};if m.epoch!=from{t.Fatal("遗漏旧代主体")};members=append(members,m)}
    if err=rows.Err();err!=nil{t.Fatal(err)};_ =rows.Close()
    if _,err=db.Exec("UPDATE meton_managed_fence SET enabled=false");err!=nil{t.Fatal(err)}
    tx,err:=db.Begin();if err!=nil{t.Fatal(err)}
    restore:=uuid.NewString()
    for _,m:=range members{
        if _,err=tx.Exec("SELECT public.meton_recover_original($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",m.env,m.user,restore,from,to,m.source,m.account,m.creation,m.dispatch,m.remote,m.marker,strings.Repeat("d",64));err!=nil{_ =tx.Rollback();t.Fatal(err)}
    }
    if err=tx.Commit();err!=nil{t.Fatal(err)}
    if _,err=db.Exec("UPDATE meton_managed_fence SET epoch=$1,enabled=true",to);err!=nil{t.Fatal(err)}
    t.Setenv("METON_MANAGED_EPOCH",strconv.FormatInt(to,10))
    return len(members)
}

/** 真实 TLS 只读供应在两次恢复间保留原观察，当前独立证据只产生一个原结案。 */
func TestRestoredProviderObservationPostgres(t *testing.T) {
    var input struct{Owner metonfee.Origin;Context map[string]any;Key SessionKey}
    raw,err:=os.ReadFile(os.Getenv("METON_RESTORED_RESULT_FIXTURE"))
    if err!=nil||json.Unmarshal(raw,&input)!=nil{t.Fatal("本轮输入缺失",err)}
    for k,v:=range map[string]string{"METON_MANAGED_ENVIRONMENT":input.Owner.Environment,"METON_MANAGED_SOURCE":input.Owner.Source,"METON_MANAGED_EPOCH":"1","METON_MANAGED_FUNDS_MODE":"s2-source-v1"}{t.Setenv(k,v)}
    open:=func(role string)(*sql.DB,*TextLedger){
        db,e:=sql.Open("postgres","host=127.0.0.1 dbname=s2_grants sslmode=disable user="+role);if e!=nil{t.Fatal(e)}
        t.Cleanup(func(){_ =db.Close()});l,e:=NewTextLedger(db);if e!=nil{t.Fatal(e)};return db,l
    }
    db,_:=open("postgres");reserve,_:=open("s2_provider_reserve");sender,_:=open("s2_resolution_prepare");complete,_:=open("s2_resolution_complete")
    _,oldRead:=open("s2_restored_read");_,oldObserve:=open("s2_resolution_observe")
    var calls atomic.Int32
    server:=httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
        calls.Add(1)
        if r.Method!="GET"||r.URL.Path!="/v1/responses/resp_restored"||r.Header.Get("Authorization")!="Bearer isolated-restored-provider"{t.Error("原只读供应路径改变")}
        w.Header().Set("Content-Type","application/json")
        _,_=w.Write([]byte(`{"id":"resp_restored","model":"meton-s2-text-fixture","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2,"input_tokens_details":{"cached_tokens":0}}}`))
    }));defer server.Close()
    target:=server.URL+"/v1/responses";sum:=sha256.Sum256([]byte(target));hash:=hex.EncodeToString(sum[:])
    spec:=metonexecution.Record{Version:1,Profile:"restored-provider-v1",ProfileHash:hash,WireProtocol:"responses",WireModel:"meton-s2-text-fixture",TargetHash:hash,BodyDigest:hash,InputBound:2,OutputBound:1}
    headers:=http.Header{"Authorization":[]string{"Bearer isolated-restored-provider"}}
    binding,e:=metonprovider.Capture(23,headers,"responses",[]byte(`{"model":"meton-s2-text-fixture","input":"isolated"}`));if e!=nil{t.Fatal(e)}
    input.Context["valid_until_ms"]=time.Now().Add(29*time.Second).UnixMilli();contextRaw,_:=json.Marshal(input.Context);contextSum:=sha256.Sum256(contextRaw);contextHash:=hex.EncodeToString(contextSum[:])
    frozen,_:=json.Marshal(spec);bound,_:=json.Marshal(binding)
    h,e:=scanHold(reserve.QueryRow(holdColumns+"reserve_provider_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9)",input.Owner.Environment,input.Owner.Source,1,string(contextRaw),contextHash,"gateway-s2",input.Key.ID,string(frozen),string(bound)))
    if e!=nil{t.Fatal("原受理",e)}
    o:=h.Origin;args:=[]any{o.Environment,o.Source,1,o.User,o.Account,o.SourceMarker,o.Caller,o.OperationID,o.SourceRequestID};var claimed bool
    e=sender.QueryRow("SELECT meton_ledger.claim_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",append(append([]any{},args...),contextHash,input.Key.ID,input.Key.Fingerprint,string(frozen))...).Scan(&claimed)
    if e!=nil||!claimed{t.Fatal("原发送",e)}
    original:=metonresult.Snapshot{FormatVersion:1,Protocol:"responses",Execution:"unknown",ResponseID:"resp_restored",ReadEnd:"read_error",BodySHA256:contextHash}
    encoded,_:=json.Marshal(original);var first json.RawMessage
    if e=complete.QueryRow("SELECT meton_ledger.complete_execution_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",append(append([]any{},args...),contextHash,string(frozen),string(encoded))...).Scan(&first);e!=nil{t.Fatal(e)}
    transport:=server.Client().Transport.(*http.Transport).Clone();transport.TLSClientConfig=transport.TLSClientConfig.Clone()
    roots:=x509.NewCertPool();roots.AddCert(server.Certificate());transport.TLSClientConfig.RootCAs=roots;transport.TLSClientConfig.InsecureSkipVerify=false
    provider,e:=metonprovider.NewReader(&http.Client{Transport:transport},[]string{target},1,2*time.Second);if e!=nil{t.Fatal(e)};defer provider.Close()
    credentials:=func(context.Context,int64)(http.Header,error){return headers.Clone(),nil};guard:=func(context.Context)error{return nil}
    evidence:=uuid.NewString();oldProof,e:=oldRead.ObserveProvider(t.Context(),o,evidence,provider,credentials,oldObserve,guard)
    if e!=nil||oldProof.Epoch!=1||calls.Load()!=1{t.Fatal("原独立观察",e)}
    population:=restoredResultAdvance(t,db,1,5)
    _,reader:=open("s2_restored_read");_,observer:=open("s2_resolution_observe");_,executor:=open("s2_resolution_apply")
    key:=ResultProofKey{PriorEvent:oldProof.PriorEvent,ContextHash:contextHash,EvidenceID:evidence}
    historic,e:=reader.FindResultProof(t.Context(),o,key)
    if e!=nil||!reflect.DeepEqual(historic,oldProof){t.Fatal("历史观察被改写或丢失",e)}
    if _,e=oldRead.FindResultProof(t.Context(),o,key);e==nil{t.Fatal("旧运行连接恢复写读权")}
    if _,e=reader.ObserveProvider(t.Context(),o,evidence,provider,credentials,observer,guard);e==nil||calls.Load()!=1{t.Fatal("旧证据被重观察或换代")}
    selection:=ResultResolutionKey{EvidenceID:evidence,CaseID:uuid.NewString(),AttemptID:uuid.NewString(),ApprovalDigest:contextHash}
    if _,e=executor.ApplyResultProof(t.Context(),o,selection);e==nil{t.Fatal("旧观察成为当前执行许可")}
    // 新材料由本测试显式安排，代表另一次当前审核；业务续审／持久许可并非本用例实现。
    fresh:=uuid.NewString();proof,e:=reader.ObserveProvider(t.Context(),o,fresh,provider,credentials,observer,guard)
    if e!=nil||proof.Epoch!=5||calls.Load()!=2{t.Fatal("当前原供应观察",e)}
    selection.EvidenceID=fresh;selection.ApprovalDigest=strings.Repeat("b",64)
    repeated,e:=reader.ObserveProvider(t.Context(),o,fresh,provider,credentials,observer,guard)
    if e!=nil||!reflect.DeepEqual(repeated,proof)||calls.Load()!=2{t.Fatal("当前证据重放重新查供应",e)}
    applied,e:=executor.ApplyResultProof(t.Context(),o,selection)
    if e!=nil||applied.Result.Posting.Funded!="2.00000000"{t.Fatal("恢复后原结案",e)}
    if _,e=executor.ApplyResultProof(t.Context(),o,selection);e!=nil{t.Fatal("原同代结案重放",e)}
    restoredResultAdvance(t,db,5,9);_,last:=open("s2_restored_read");_,late:=open("s2_resolution_apply")
    resolved,e:=last.FindResultResolution(t.Context(),o,selection)
    if e!=nil||!reflect.DeepEqual(applied,resolved){t.Fatal("再次恢复丢失原结案",e)}
    if _,e=late.ApplyResultProof(t.Context(),o,selection);e==nil{t.Fatal("上代证据重新执行")}
    latest,e:=last.FindResultProof(t.Context(),o,ResultProofKey{PriorEvent:proof.PriorEvent,ContextHash:contextHash,EvidenceID:fresh})
    if e!=nil||latest.Epoch!=5{t.Fatal("把历史观察登记代次改成当前",e)}
    var admission json.RawMessage
    if e=db.QueryRow("SELECT meton_ledger.read_text_reference($1,$2,9,(SELECT operation FROM meton_managed_creations WHERE source_marker=$3),$4,$5,NULL)",o.Environment,o.Source,o.SourceMarker,o.Caller,o.OperationID).Scan(&admission);e!=nil{t.Fatal(e)}
    // 原创建号从可信来源关联读取，不从恢复后的受理材料猜编号。
    if len(admission)==0{t.Fatal("原受理缺失")}
    var originalAdmission metonmodel.Admission;if json.Unmarshal(admission,&originalAdmission)!=nil{t.Fatal("原受理格式")}
    request:=metonmodel.ReconciliationRequest{Version:1,Epoch:9,UntilMS:time.Now().Add(time.Second).UnixMilli(),Admission:originalAdmission,
        ReconciliationSelection:metonmodel.ReconciliationSelection{EvidenceID:fresh,CaseID:selection.CaseID,AttemptID:selection.AttemptID,ApprovalDigest:selection.ApprovalDigest}}
    wire,_:=json.Marshal(request);if _,e=metonmodel.ReadReconciliation(wire);e!=nil{t.Fatal("历史原受理不能查询",e)}
    request.Admission.AcceptedEpoch=10;wire,_=json.Marshal(request);if _,e=metonmodel.ReadReconciliation(wire);e==nil{t.Fatal("未来受理放行")}
    var fees,active int;var balance string
    e=db.QueryRow("SELECT (SELECT count(*) FROM meton_ledger.text_fee_reports WHERE request_id=$1),(SELECT count(*) FROM api_keys k JOIN meton_managed_keys x ON x.remote_key=k.id WHERE x.source_marker=$2 AND k.status='active'),u.balance::text FROM users u JOIN meton_managed_creations c ON c.remote_user=u.id WHERE c.source_marker=$2",o.SourceRequestID,o.SourceMarker).Scan(&fees,&active,&balance)
    if e!=nil||fees!=1||active!=0||balance!="3.00000000"{t.Fatal("重复扣费或旧 Key 复活",e)}
    output,_:=json.Marshal(map[string]any{"format_version":1,"origin":o,"old_proof":oldProof,"current_proof":proof,"resolution":resolved,
        "http_gets":calls.Load(),"model_posts":0,"fees":fees,"active_keys":active,"balance":balance,"source_population":population,"authority_epochs":[]int{1,5,9},"meton_reapproval_tested":false})
    if e=os.WriteFile(os.Getenv("METON_RESTORED_RESULT_EXPORT"),output,0600);e!=nil{t.Fatal(e)}
}
