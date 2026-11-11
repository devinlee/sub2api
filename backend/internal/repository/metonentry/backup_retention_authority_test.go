//go:build unit && meton_managed

package metonentry

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

type backupAuthorityFixture struct {
	t         *testing.T
	server    *httptest.Server
	path      string
	config    backupAuthorityConfiguration
	until     time.Time
	calls     atomic.Int64
	mu        sync.Mutex
	queries   []backupAuthorityQuery
	customize func(http.ResponseWriter, *http.Request, backupAuthorityQuery, *backupAuthorityObservation) bool
}

/** 生成本用例独立 CA 和双向证书，不读取真实部署秘密。 */
func backupAuthorityCertificate(t *testing.T, ca *x509.Certificate, caKey *ecdsa.PrivateKey, server bool) ([]byte, []byte, *x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "isolated-backup-authority"}, NotBefore: time.Now().Add(-time.Minute),
		NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	parent, signer := ca, caKey
	if ca == nil {
		template.IsCA = true
		template.BasicConstraintsValid = true
		template.KeyUsage |= x509.KeyUsageCertSign
		parent = template
		signer = key
	} else if server {
		template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		template.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
	} else {
		template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), certificate, key
}

/** 实际 HTTPS 服务只接收本夹具的客户端证书，回复模拟当前观察，原控制库沿已有证据另行组合。 */
func newBackupAuthorityFixture(t *testing.T) *backupAuthorityFixture {
	t.Helper()
	f := &backupAuthorityFixture{t: t, until: time.Now().UTC().Add(time.Minute).Truncate(time.Millisecond)}
	caPEM, _, ca, key := backupAuthorityCertificate(t, nil, nil, false)
	serverPEM, serverKey, _, _ := backupAuthorityCertificate(t, ca, key, true)
	clientPEM, clientKey, _, _ := backupAuthorityCertificate(t, ca, key, false)
	serverCertificate, err := tls.X509KeyPair(serverPEM, serverKey)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(caPEM)
	f.server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.Method != "POST" || r.URL.RequestURI() != backupAuthorityPath || r.TLS == nil || len(r.TLS.VerifiedChains) != 1 ||
			r.Header.Get("Authorization") != "Bearer test-personnel-proof" || len(r.Cookies()) != 0 || r.Header.Get("Content-Type") != "application/json" {
			t.Error("请求没有保持固定范围、证明和双向 TLS")
			http.Error(w, "rejected", 403)
			return
		}
		raw, err := io.ReadAll(io.LimitReader(r.Body, 4097))
		var q backupAuthorityQuery
		if err != nil || len(raw) > 4096 || metonexecution.DecodeStrict(raw, &q) != nil || q.FormatVersion != 1 || !backupAuthorityID(q.RequestID) {
			t.Error("请求格式无效")
			http.Error(w, "invalid", 400)
			return
		}
		f.queries = append(f.queries, q)
		destructive := q.Purpose == "cash.backup.retirement.execute.v1" || q.Purpose == "cash.backup.retirement.resume.v1"
		restore := false
		a := backupRetentionAuthority{configuration: f.config}
		o := &backupAuthorityObservation{RequestID: q.RequestID, Environment: f.config.Environment, Source: f.config.Source,
			AuthorityReference: q.AuthorityReference, Purpose: q.Purpose, OperationID: q.OperationID, TargetID: q.TargetID, KeeperID: q.KeeperID,
			PlanDigest: q.PlanDigest, PersonID: "22222222-2222-4222-8222-222222222222", PersonVersion: 1, Generation: 1, RecoveryState: "active",
			Until: f.until, ObservedAt: time.Now().UTC(), IntentDigest: a.digest(q), AuditEventID: uuid.NewString(), DeletionAuthorized: &destructive, RecoveryExecutionAuthorized: &restore}
		w.Header().Set("Content-Type", "application/json")
		if f.customize != nil && f.customize(w, r, q, o) {
			return
		}
		_ = json.NewEncoder(w).Encode(backupAuthorityReply{State: "current", Observation: o})
	}))
	f.server.Config.ErrorLog = log.New(io.Discard, "", 0)
	f.server.TLS = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{serverCertificate}, ClientCAs: roots, ClientAuth: tls.RequireAndVerifyClientCert}
	f.server.StartTLS()
	t.Cleanup(f.server.Close)
	base := t.TempDir()
	f.path = filepath.Join(base, "authority.json")
	material := func(name string, raw []byte) backupAuthorityMaterial {
		if err := os.WriteFile(filepath.Join(base, name), raw, 0600); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(raw)
		return backupAuthorityMaterial{name, hex.EncodeToString(sum[:])}
	}
	f.config = backupAuthorityConfiguration{FormatVersion: 1, Environment: "s3-isolated", Source: "backup-authority-fixture", AuthorityReference: "current-test-roster-v1",
		Endpoint: f.server.URL + backupAuthorityPath, CA: material("ca.pem", caPEM), Certificate: material("client.pem", clientPEM), PrivateKey: material("client-key.pem", clientKey)}
	f.writeConfig(f.config)
	return f
}

/** 只写夹具自己的受控文件，便于核对途中变化后的永久退役。 */
func (f *backupAuthorityFixture) writeConfig(cfg backupAuthorityConfiguration) {
	raw, err := json.Marshal(cfg)
	if err != nil {
		f.t.Fatal(err)
	}
	if err = os.WriteFile(f.path, raw, 0600); err != nil {
		f.t.Fatal(err)
	}
}

/** 每个实例有独立关闭权，不借全局 HTTP 客户端或代理。 */
func (f *backupAuthorityFixture) open() service.BackupRetentionAuthority {
	f.t.Helper()
	a, close, err := OpenBackupRetentionAuthority(f.path, f.config.Environment, f.config.Source)
	if err != nil || a == nil {
		f.t.Fatalf("不能装配测试权威: %v", err)
	}
	f.t.Cleanup(close)
	return a
}

/** 修改回复行为前持锁，确保上一个 HTTP 处理已结束。 */
func (f *backupAuthorityFixture) reply(fn func(http.ResponseWriter, *http.Request, backupAuthorityQuery, *backupAuthorityObservation) bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.customize = fn
}

func backupAuthorityIntent(action string) service.BackupRetentionIntent {
	return service.BackupRetentionIntent{Purpose: "cash.backup.retirement." + action + ".v1", Environment: "s3-isolated", Source: "backup-authority-fixture",
		Operation: "11111111-1111-4111-8111-111111111111", Target: "target-backup", Keeper: "keeper-backup", Digest: strings.Repeat("a", 64)}
}

func requireBackupAuthorityRejected(t *testing.T, a service.BackupRetentionAuthority, intent service.BackupRetentionIntent) {
	t.Helper()
	person, err := a.Current(context.Background(), "test-personnel-proof", intent)
	if !errors.Is(err, service.ErrBackupRetirementUnavailable) || person != (service.BackupRetentionOperator{}) {
		t.Fatalf("拒绝时不得返回部分许可: %+v %v", person, err)
	}
}

func TestMetonBackupAuthority_CurrentIntentAndFreshObservation(t *testing.T) {
	f := newBackupAuthorityFixture(t)
	a := f.open()
	intent := backupAuthorityIntent("inspect")
	first, err := a.Current(context.Background(), "test-personnel-proof", intent)
	if err != nil {
		t.Fatal(err)
	}
	second, err := a.Current(context.Background(), "test-personnel-proof", intent)
	if err != nil || first != second || !first.Until.Equal(f.until) {
		t.Fatal("重复观察改变了原人员证明")
	}
	f.mu.Lock()
	queries := append([]backupAuthorityQuery{}, f.queries...)
	f.mu.Unlock()
	if len(queries) != 2 || queries[0].RequestID == queries[1].RequestID {
		t.Fatal("每次往返须有独立关联号")
	}
	// 固定向量由同一 .NET 契约的换行编码独立计算，避免两端各自自洽但不相同。
	if a.(*backupRetentionAuthority).digest(queries[0]) != "af05937b14b0d1c32a91b01e4bdb17b49c07308746225d2fc67625bdd73901b4" {
		t.Fatal("跨语言意图摘要改变")
	}
	for _, action := range []string{"execute", "reconcile", "resume"} {
		if _, err = a.Current(context.Background(), "test-personnel-proof", backupAuthorityIntent(action)); err != nil {
			t.Fatal(action, err)
		}
	}
	f.reply(func(_ http.ResponseWriter, _ *http.Request, _ backupAuthorityQuery, o *backupAuthorityObservation) bool {
		o.Generation = 2
		o.PersonVersion = 2
		return false
	})
	next, err := a.Current(context.Background(), "test-personnel-proof", intent)
	if err != nil || next.Generation != 2 || next.Version != 2 {
		t.Fatal("没有查询当前代次和人员")
	}
	f.reply(func(w http.ResponseWriter, _ *http.Request, _ backupAuthorityQuery, _ *backupAuthorityObservation) bool {
		w.WriteHeader(403)
		return true
	})
	requireBackupAuthorityRejected(t, a, intent)
	f.reply(func(_ http.ResponseWriter, _ *http.Request, _ backupAuthorityQuery, o *backupAuthorityObservation) bool {
		o.RecoveryState = "closed"
		return false
	})
	requireBackupAuthorityRejected(t, a, backupAuthorityIntent("execute"))
	if _, err = a.Current(context.Background(), "test-personnel-proof", backupAuthorityIntent("reconcile")); err != nil {
		t.Fatal("关闭后仍应可核对原操作", err)
	}
}

func TestMetonBackupAuthority_RejectsMismatchedOrIncompleteReply(t *testing.T) {
	f := newBackupAuthorityFixture(t)
	a := f.open()
	cases := map[string]func(*backupAuthorityObservation){
		"nonce":              func(o *backupAuthorityObservation) { o.RequestID = uuid.NewString() },
		"environment":        func(o *backupAuthorityObservation) { o.Environment = "other" },
		"source":             func(o *backupAuthorityObservation) { o.Source = "other" },
		"authority":          func(o *backupAuthorityObservation) { o.AuthorityReference = "old-roster" },
		"purpose":            func(o *backupAuthorityObservation) { o.Purpose = "cash.backup.retirement.inspect.v1" },
		"operation":          func(o *backupAuthorityObservation) { o.OperationID = uuid.NewString() },
		"target":             func(o *backupAuthorityObservation) { o.TargetID = "other-backup" },
		"keeper":             func(o *backupAuthorityObservation) { o.KeeperID = "other-copy" },
		"plan":               func(o *backupAuthorityObservation) { o.PlanDigest = strings.Repeat("b", 64) },
		"intent":             func(o *backupAuthorityObservation) { o.IntentDigest = strings.Repeat("b", 64) },
		"person":             func(o *backupAuthorityObservation) { o.PersonID = uuid.Nil.String() },
		"person-version":     func(o *backupAuthorityObservation) { o.PersonVersion = 0 },
		"generation":         func(o *backupAuthorityObservation) { o.Generation = 0 },
		"recovery-state":     func(o *backupAuthorityObservation) { o.RecoveryState = "unknown" },
		"expired":            func(o *backupAuthorityObservation) { o.Until = time.Now().Add(-time.Second) },
		"old-observation":    func(o *backupAuthorityObservation) { o.ObservedAt = time.Now().Add(-time.Minute) },
		"future-observation": func(o *backupAuthorityObservation) { o.ObservedAt = time.Now().Add(time.Minute) },
		"audit":              func(o *backupAuthorityObservation) { o.AuditEventID = "" },
		"missing-deletion":   func(o *backupAuthorityObservation) { o.DeletionAuthorized = nil },
		"wrong-deletion":     func(o *backupAuthorityObservation) { value := false; o.DeletionAuthorized = &value },
		"missing-restore":    func(o *backupAuthorityObservation) { o.RecoveryExecutionAuthorized = nil },
		"restore-authorized": func(o *backupAuthorityObservation) { value := true; o.RecoveryExecutionAuthorized = &value },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			f.reply(func(_ http.ResponseWriter, _ *http.Request, _ backupAuthorityQuery, o *backupAuthorityObservation) bool {
				change(o)
				return false
			})
			before := f.calls.Load()
			requireBackupAuthorityRejected(t, a, backupAuthorityIntent("execute"))
			if f.calls.Load() != before+1 {
				t.Fatal("必须仅查询一次")
			}
		})
	}
	for _, kind := range []string{"unknown-field", "duplicate-field", "missing-observation", "unknown-state", "truncated", "oversized"} {
		t.Run(kind, func(t *testing.T) {
			f.reply(func(w http.ResponseWriter, _ *http.Request, _ backupAuthorityQuery, o *backupAuthorityObservation) bool {
				raw, _ := json.Marshal(backupAuthorityReply{"current", o})
				switch kind {
				case "unknown-field":
					raw = append([]byte(`{"extra":true,`), raw[1:]...)
				case "duplicate-field":
					raw = append([]byte(`{"state":"current",`), raw[1:]...)
				case "missing-observation":
					raw = []byte(`{"state":"current"}`)
				case "unknown-state":
					raw = []byte(`{"state":"unknown","observation":null}`)
				case "truncated":
					raw = raw[:len(raw)/2]
				case "oversized":
					raw = []byte(strings.Repeat(" ", 16385))
				}
				_, _ = w.Write(raw)
				return true
			})
			requireBackupAuthorityRejected(t, a, backupAuthorityIntent("inspect"))
		})
	}
	f.reply(nil)
	before := f.calls.Load()
	for _, change := range []func(*service.BackupRetentionIntent){
		func(i *service.BackupRetentionIntent) { i.Purpose = "cash.backup.retirement.delete.v1" },
		func(i *service.BackupRetentionIntent) { i.Source = "other" }, func(i *service.BackupRetentionIntent) { i.Operation = uuid.Nil.String() },
		func(i *service.BackupRetentionIntent) { i.Digest = "invalid" }, func(i *service.BackupRetentionIntent) { i.Target = "target\nother" },
		func(i *service.BackupRetentionIntent) { i.Keeper = i.Target },
	} {
		intent := backupAuthorityIntent("inspect")
		change(&intent)
		requireBackupAuthorityRejected(t, a, intent)
	}
	if f.calls.Load() != before {
		t.Fatal("无效意图不应发出")
	}
}

func TestMetonBackupAuthority_TransportDoesNotReplayOrRedirect(t *testing.T) {
	f := newBackupAuthorityFixture(t)
	a := f.open()
	var redirected atomic.Int64
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { redirected.Add(1); w.WriteHeader(200) }))
	defer target.Close()
	for _, status := range []int{301, 302, 307, 308, 429, 500, 503} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			f.reply(func(w http.ResponseWriter, _ *http.Request, _ backupAuthorityQuery, _ *backupAuthorityObservation) bool {
				w.Header().Set("Location", target.URL)
				w.WriteHeader(status)
				return true
			})
			before := f.calls.Load()
			requireBackupAuthorityRejected(t, a, backupAuthorityIntent("execute"))
			if f.calls.Load() != before+1 || redirected.Load() != 0 {
				t.Fatal("不能自动重发或转发人员证明")
			}
		})
	}
	f.reply(func(w http.ResponseWriter, r *http.Request, _ backupAuthorityQuery, _ *backupAuthorityObservation) bool {
		<-r.Context().Done()
		return true
	})
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	if _, err := a.Current(ctx, "test-personnel-proof", backupAuthorityIntent("inspect")); err == nil {
		t.Fatal("超时不能返回旧观察")
	}
	f.reply(nil)
	before := f.calls.Load()
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	if _, err := a.Current(cancelled, "test-personnel-proof", backupAuthorityIntent("inspect")); err == nil || f.calls.Load() != before {
		t.Fatal("取消后不应派发")
	}
	f.server.CloseClientConnections()
	transport := a.(*backupRetentionAuthority).transport
	transport.TLSClientConfig.Certificates = nil
	requireBackupAuthorityRejected(t, a, backupAuthorityIntent("inspect"))
	if f.calls.Load() != before {
		t.Fatal("没有客户端证书不能到达端点")
	}
}

func TestMetonBackupAuthority_ConfigurationChangeRetiresOnlyOriginalClient(t *testing.T) {
	f := newBackupAuthorityFixture(t)
	if a, close, err := OpenBackupRetentionAuthority("", f.config.Environment, f.config.Source); err != nil || a != nil {
		t.Fatal("缺省必须关闭")
	} else {
		close()
	}
	for _, name := range []string{"authority.json", "ca.pem", "client.pem", "client-key.pem"} {
		t.Run(name, func(t *testing.T) {
			original := f.open()
			other := f.open()
			path := filepath.Join(filepath.Dir(f.path), name)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			f.reply(func(_ http.ResponseWriter, _ *http.Request, _ backupAuthorityQuery, _ *backupAuthorityObservation) bool {
				if err := os.WriteFile(path, append(append([]byte{}, raw...), ' '), 0600); err != nil {
					t.Error(err)
				}
				return false
			})
			requireBackupAuthorityRejected(t, original, backupAuthorityIntent("inspect"))
			f.reply(nil)
			if err = os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			before := f.calls.Load()
			requireBackupAuthorityRejected(t, original, backupAuthorityIntent("inspect"))
			if f.calls.Load() != before {
				t.Fatal("换回原文件不能唤醒已退役客户端")
			}
			if _, err = other.Current(context.Background(), "test-personnel-proof", backupAuthorityIntent("inspect")); err != nil {
				t.Fatal("关闭不能影响另一实例", err)
			}
		})
	}
	for _, change := range []func(*backupAuthorityConfiguration){
		func(c *backupAuthorityConfiguration) { c.Endpoint = strings.Replace(c.Endpoint, "https:", "http:", 1) },
		func(c *backupAuthorityConfiguration) { c.Endpoint += "?route=other" }, func(c *backupAuthorityConfiguration) { c.Endpoint += "#other" },
		func(c *backupAuthorityConfiguration) { c.Source = "other" }, func(c *backupAuthorityConfiguration) { c.CA.SHA256 = strings.Repeat("0", 64) },
		func(c *backupAuthorityConfiguration) {
			c.PrivateKey.Path = "client.pem"
			c.PrivateKey.SHA256 = c.Certificate.SHA256
		},
	} {
		cfg := f.config
		change(&cfg)
		f.writeConfig(cfg)
		if a, close, err := OpenBackupRetentionAuthority(f.path, f.config.Environment, f.config.Source); err == nil || a != nil {
			close()
			t.Fatal("无效配置不能装配")
		}
	}
	f.writeConfig(f.config)
}
