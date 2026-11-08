// Package metondispatch 核验网关签名的原调用。通过证明只确认上下文，发送权仍由来源事务授予。
package metondispatch

import (
	"bytes"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const ContextHeader = "Meton-Model-Context"
const ProofHeader = "Meton-Service-Proof"
const Purpose = "model-dispatch.v1"

var ErrProof = errors.New("original model dispatch unconfirmed")
var label = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,120}$`)
var model = regexp.MustCompile(`^[A-Za-z0-9_./:-]{1,160}$`)
var uuid = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var digest = regexp.MustCompile(`^[0-9a-f]{64}$`)
var encoded = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
var nonce = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Context 的会话和恢复代次不参加原调用的去重键，只限制这次发送者。
type Context struct {
	Version                 int    `json:"version"`
	Environment             string `json:"environment"`
	Source                  string `json:"source"`
	User                    string `json:"user"`
	Account                 string `json:"account"`
	Caller                  string `json:"caller"`
	OperationID             string `json:"operation_id"`
	Protocol                string `json:"protocol"`
	Model                   string `json:"model"`
	DigestVersion           int    `json:"digest_version"`
	InputDigest             string `json:"input_digest"`
	Epoch                   int64  `json:"epoch"`
	Session                 string `json:"session"`
	Family                  string `json:"family"`
	SecurityVersion         int64  `json:"security_version"`
	IdentityRecoveryVersion int64  `json:"identity_recovery_version"`
	Binding                 string `json:"binding"`
	Generation              int64  `json:"generation"`
	ServiceVersion          int64  `json:"service_version"`
	TokenID                 string `json:"token_id"`
	ModelGrantID            string `json:"model_grant_id"`
	Worker                  string `json:"worker"`
	Dispatch                string `json:"dispatch"`
	ValidUntilMS            int64  `json:"valid_until_ms"`
	KeyDigest               string `json:"key_digest"`
}

type proof struct {
	ServiceID string `json:"ServiceId"`
	ClusterID string `json:"ClusterId"`
	Purpose   string `json:"Purpose"`
	Target    string `json:"Target"`
	IssuedAt  int64  `json:"IssuedAt"`
	ExpiresAt int64  `json:"ExpiresAt"`
	Nonce     string `json:"Nonce"`
	Signature string `json:"Signature"`
}

// Verifier 的公钥只能由部署装配提供；消息中的服务 ID 只能选择已经固定的公钥。
type Verifier struct {
	environment, source string
	epoch               int64
	keys                map[string]*x509.Certificate
}

/** NewVerifier 不接受无版本或共享通配信任；复制映射防止外部增添新的服务身份。 */
func NewVerifier(environment, source string, epoch int64, keys map[string]*x509.Certificate) (*Verifier, error) {
	if !label.MatchString(environment) || !label.MatchString(source) || epoch < 1 || len(keys) < 1 || len(keys) > 128 {
		return nil, ErrProof
	}
	v := &Verifier{environment: environment, source: source, epoch: epoch, keys: make(map[string]*x509.Certificate)}
	for id, cert := range keys {
		if !label.MatchString(id) || cert == nil {
			return nil, ErrProof
		}
		// 按原 DER 重新解析，调用方后来改结构体或公钥不能改变本次信任配置。
		copy, err := x509.ParseCertificate(cert.Raw)
		if err != nil {
			return nil, ErrProof
		}
		key, ok := copy.PublicKey.(*rsa.PublicKey)
		client := false
		for _, usage := range copy.ExtKeyUsage {
			if usage == x509.ExtKeyUsageClientAuth {
				client = true
			}
		}
		if !ok || key.N.BitLen() < 2048 || key.N.BitLen() > 4096 || !client || copy.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
			return nil, ErrProof
		}
		v.keys[id] = copy
	}
	return v, nil
}

// Verified 不暴露可写上下文。只读查询不能构造它，零值也不能换取发送权。
type Verified struct {
	context              Context
	contextHash, service string
	verified             bool
}

func (v *Verified) Context() Context {
	if v == nil {
		return Context{}
	}
	return v.context
}
func (v *Verified) Hash() string {
	if v == nil {
		return ""
	}
	return v.contextHash
}
func (v *Verified) Service() string {
	if v == nil {
		return ""
	}
	return v.service
}
func (v *Verified) Current(now time.Time) bool {
	return v != nil && v.verified && now.UnixMilli() < v.context.ValidUntilMS
}

/** Verify 同时核对路径、原正文和实际 Bearer 指纹；任何未知字段或重复字段均拒绝。 */
func (v *Verifier) Verify(method, path, header, serviceProof string, body, key []byte, now time.Time) (*Verified, error) {
	if v == nil || method != "POST" || (path != "/v1/responses" && path != "/v1/chat/completions") || len(header) > 8192 || !encoded.MatchString(header) ||
		len(body) == 0 || len(body) > 256*1024 || len(key) == 0 || len(key) > 16384 {
		return nil, ErrProof
	}
	raw, err := base64.RawURLEncoding.Strict().DecodeString(header)
	if err != nil || len(raw) > 4096 {
		return nil, ErrProof
	}
	var c Context
	var p proof
	if strict(raw, &c) != nil || strict([]byte(serviceProof), &p) != nil || !valid(c) || c.Environment != v.environment || c.Source != v.source || c.Epoch != v.epoch ||
		p.ClusterID != v.environment || p.Purpose != Purpose || !nonce.MatchString(p.Nonce) || p.IssuedAt <= 0 || p.IssuedAt > now.Unix() ||
		p.ExpiresAt <= now.Unix() || p.ExpiresAt <= p.IssuedAt || p.ExpiresAt-p.IssuedAt > 5 ||
		c.ValidUntilMS <= now.UnixMilli() || c.ValidUntilMS > (p.IssuedAt+31)*1000 ||
		(c.Protocol == "responses") != (path == "/v1/responses") || c.InputDigest != hash(body) || c.KeyDigest != hash(key) {
		return nil, ErrProof
	}
	target := "meton-model-dispatch.v1:POST:" + path + ":" + hash(raw)
	cert := v.keys[p.ServiceID]
	if p.Target != target || cert == nil || now.Before(cert.NotBefore) || !now.Before(cert.NotAfter) || len(p.Signature) > 1024 {
		return nil, ErrProof
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(p.Signature)
	if err != nil {
		return nil, ErrProof
	}
	message := payload(p.ServiceID, p.ClusterID, p.Purpose, p.Target, strconv.FormatInt(p.IssuedAt, 10), strconv.FormatInt(p.ExpiresAt, 10), p.Nonce)
	sum := sha256.Sum256(message)
	if rsa.VerifyPSS(cert.PublicKey.(*rsa.PublicKey), crypto.SHA256, sum[:], signature, &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash}) != nil {
		return nil, ErrProof
	}
	return &Verified{context: c, contextHash: hash(raw), service: p.ServiceID, verified: true}, nil
}

func valid(c Context) bool {
	if c.Version != 1 || !label.MatchString(c.Environment) || !label.MatchString(c.Source) || !model.MatchString(c.Model) ||
		(c.Caller != "meton.chat.v1" && c.Caller != "meton.oc07.v1") || (c.Protocol != "responses" && c.Protocol != "chat_completions") ||
		c.DigestVersion != 1 || !digest.MatchString(c.InputDigest) || !digest.MatchString(c.KeyDigest) || c.Epoch < 1 ||
		c.SecurityVersion < 1 || c.IdentityRecoveryVersion < 1 || c.Generation < 1 || c.ServiceVersion < 1 {
		return false
	}
	for _, id := range []string{c.User, c.Account, c.OperationID, c.Session, c.Family, c.Binding, c.TokenID, c.ModelGrantID, c.Worker, c.Dispatch} {
		if !uuid.MatchString(id) || id == "00000000-0000-0000-0000-000000000000" {
			return false
		}
	}
	return true
}

func hash(raw []byte) string { sum := sha256.Sum256(raw); return hex.EncodeToString(sum[:]) }
func payload(fields ...string) []byte {
	var out strings.Builder
	for _, field := range fields {
		out.WriteString(strconv.Itoa(len([]byte(field))))
		out.WriteByte(':')
		out.WriteString(field)
	}
	return []byte(out.String())
}

/** strict 限定平面对象的精确字段集合，避免 JSON 的大小写别名与重复键覆盖。 */
func strict(raw []byte, dest any) error {
	if len(raw) == 0 || len(raw) > 4096 {
		return ErrProof
	}
	shape, err := json.Marshal(dest)
	if err != nil {
		return ErrProof
	}
	var allowed map[string]json.RawMessage
	if json.Unmarshal(shape, &allowed) != nil {
		return ErrProof
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	if first, err := dec.Token(); err != nil || first != json.Delim('{') {
		return ErrProof
	}
	seen := map[string]bool{}
	for dec.More() {
		token, err := dec.Token()
		name, ok := token.(string)
		if err != nil || !ok || seen[name] {
			return ErrProof
		}
		if _, ok := allowed[name]; !ok {
			return ErrProof
		}
		seen[name] = true
		var value json.RawMessage
		if dec.Decode(&value) != nil || bytes.Equal(value, []byte("null")) {
			return ErrProof
		}
	}
	if end, err := dec.Token(); err != nil || end != json.Delim('}') || len(seen) != len(allowed) {
		return ErrProof
	}
	if _, err := dec.Token(); err != io.EOF {
		return ErrProof
	}
	if json.Unmarshal(raw, dest) != nil {
		return ErrProof
	}
	return nil
}
