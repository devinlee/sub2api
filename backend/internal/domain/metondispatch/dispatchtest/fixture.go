//go:build dispatch_integration

// Package dispatchtest 只在隔离联验构建中生成合成签名，不装入托管服务产物。
package dispatchtest

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/google/uuid"
)

type Signer struct {
	Key         *rsa.PrivateKey
	Certificate *x509.Certificate
	Verifier    *metondispatch.Verifier
}
type Proof struct {
	ServiceId, ClusterId, Purpose, Target string
	IssuedAt, ExpiresAt                   int64
	Nonce, Signature                      string
}

func New(t *testing.T) *Signer {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "synthetic-gateway"}, NotBefore: time.Now().Add(-time.Minute),
		NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(raw)
	if err != nil {
		t.Fatal(err)
	}
	v, err := metondispatch.NewVerifier("s2-isolated", "s2-managed", 1, map[string]*x509.Certificate{"gateway-s2": cert})
	if err != nil {
		t.Fatal(err)
	}
	return &Signer{key, cert, v}
}

func Hash(raw []byte) string { s := sha256.Sum256(raw); return hex.EncodeToString(s[:]) }
func Context(body, key []byte) metondispatch.Context {
	return metondispatch.Context{Version: 1, Environment: "s2-isolated", Source: "s2-managed", User: uuid.NewString(), Account: uuid.NewString(),
		Caller: "meton.chat.v1", OperationID: uuid.NewString(), Protocol: "responses", Model: "meton-s2-text-fixture", DigestVersion: 1, InputDigest: Hash(body), Epoch: 1,
		Session: uuid.NewString(), Family: uuid.NewString(), SecurityVersion: 1, IdentityRecoveryVersion: 1, Binding: uuid.NewString(), Generation: 1, ServiceVersion: 1,
		TokenID: uuid.NewString(), ModelGrantID: uuid.NewString(), Worker: uuid.NewString(), Dispatch: uuid.NewString(), ValidUntilMS: time.Now().Add(20 * time.Second).UnixMilli(), KeyDigest: Hash(key)}
}

func (s *Signer) Encode(t *testing.T, c metondispatch.Context, path string, now time.Time) (string, string) {
	t.Helper()
	raw, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	return s.Raw(t, raw, path, now)
}

func (s *Signer) Raw(t *testing.T, raw []byte, path string, now time.Time) (string, string) {
	t.Helper()
	p := Proof{ServiceId: "gateway-s2", ClusterId: "s2-isolated", Purpose: metondispatch.Purpose,
		Target: "meton-model-dispatch.v1:POST:" + path + ":" + Hash(raw), IssuedAt: now.Unix(), ExpiresAt: now.Unix() + 5, Nonce: strings.ReplaceAll(uuid.NewString(), "-", "")}
	var payload strings.Builder
	for _, f := range []string{p.ServiceId, p.ClusterId, p.Purpose, p.Target, strconv.FormatInt(p.IssuedAt, 10), strconv.FormatInt(p.ExpiresAt, 10), p.Nonce} {
		payload.WriteString(strconv.Itoa(len([]byte(f))))
		payload.WriteByte(':')
		payload.WriteString(f)
	}
	sum := sha256.Sum256([]byte(payload.String()))
	signature, err := rsa.SignPSS(rand.Reader, s.Key, crypto.SHA256, sum[:], &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash})
	if err != nil {
		t.Fatal(err)
	}
	p.Signature = base64.StdEncoding.EncodeToString(signature)
	proof, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), string(proof)
}

func (s *Signer) Verify(t *testing.T, c metondispatch.Context, body, key []byte) *metondispatch.Verified {
	t.Helper()
	path := "/v1/responses"
	if c.Protocol == "chat_completions" {
		path = "/v1/chat/completions"
	}
	now := time.Now()
	header, proof := s.Encode(t, c, path, now)
	v, err := s.Verifier.Verify("POST", path, header, proof, body, key, now)
	if err != nil {
		t.Fatal(err)
	}
	return v
}
