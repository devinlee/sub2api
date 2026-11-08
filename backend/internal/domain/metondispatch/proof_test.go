//go:build dispatch_integration

package metondispatch_test

import (
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
)

/** TestModelDispatchProof 核验真 RSA 签名及上下文，负例不会仅因无效签名而漏测字段约束。 */
func TestModelDispatchProof(t *testing.T) {
	s := dispatchtest.New(t)
	body, key := []byte(`{"model":"meton-s2-text-fixture","input":"test"}`), []byte("synthetic-session-key")
	c := dispatchtest.Context(body, key)
	now := time.Now()
	header, proof := s.Encode(t, c, "/v1/responses", now)
	verified, err := s.Verifier.Verify("POST", "/v1/responses", header, proof, body, key, now)
	if err != nil || !verified.Current(now) || verified.Context() != c || verified.Hash() == "" {
		t.Fatal("valid original proof rejected", err)
	}
	for _, name := range []string{"body", "key", "path", "query", "method", "signature", "purpose", "foreign-service", "expired", "future", "encoded-newline", "encoded-padding", "tampered-context"} {
		t.Run(name, func(t *testing.T) {
			method, path, h, p, b, k, at := "POST", "/v1/responses", header, proof, body, key, now
			switch name {
			case "body":
				b = []byte(`{}`)
			case "key":
				k = []byte("other-session")
			case "path":
				path = "/v1/chat/completions"
			case "query":
				path += "?retry=1"
			case "method":
				method = "GET"
			case "signature":
				var q dispatchtest.Proof
				_ = json.Unmarshal([]byte(p), &q)
				q.Signature = strings.Repeat("A", len(q.Signature))
				raw, _ := json.Marshal(q)
				p = string(raw)
			case "purpose":
				p = strings.Replace(p, "model-dispatch.v1", "model-material.v1", 1)
			case "foreign-service":
				p = strings.Replace(p, "gateway-s2", "gateway-unknown", 1)
			case "expired":
				at = now.Add(5 * time.Second)
			case "future":
				at = now.Add(-time.Second)
			case "encoded-newline":
				h += "\r\n"
			case "encoded-padding":
				h += "="
			case "tampered-context":
				raw, _ := base64.RawURLEncoding.DecodeString(h)
				h = base64.RawURLEncoding.EncodeToString([]byte(strings.Replace(string(raw), c.Account, c.User, 1)))
			}
			if v, e := s.Verifier.Verify(method, path, h, p, b, k, at); e == nil || v != nil {
				t.Fatal("invalid dispatch accepted")
			}
		})
	}
	for _, name := range []string{"duplicate", "alias", "unknown", "missing", "null", "float", "zero-generation", "zero-owner", "expired-context", "extended-context", "wrong-source", "wrong-epoch"} {
		t.Run(name, func(t *testing.T) {
			b, _ := json.Marshal(c)
			raw := string(b)
			switch name {
			case "duplicate":
				raw = strings.Replace(raw, `"version":1`, `"version":1,"version":1`, 1)
			case "alias":
				raw = strings.Replace(raw, `"version":1`, `"Version":1`, 1)
			case "unknown":
				raw = strings.Replace(raw, `"version":1`, `"version":1,"extra":"x"`, 1)
			case "missing":
				raw = strings.Replace(raw, `"version":1,`, "", 1)
			case "null":
				raw = strings.Replace(raw, `"version":1`, `"version":null`, 1)
			case "float":
				raw = strings.Replace(raw, `"version":1`, `"version":1.0`, 1)
			default:
				changed := c
				switch name {
				case "zero-generation":
					changed.Generation = 0
				case "zero-owner":
					changed.User = "00000000-0000-0000-0000-000000000000"
				case "expired-context":
					changed.ValidUntilMS = now.UnixMilli()
				case "extended-context":
					changed.ValidUntilMS = now.Add(time.Minute).UnixMilli()
				case "wrong-source":
					changed.Source = "other-source"
				case "wrong-epoch":
					changed.Epoch++
				}
				b, _ = json.Marshal(changed)
				raw = string(b)
			}
			h, p := s.Raw(t, []byte(raw), "/v1/responses", now)
			if v, e := s.Verifier.Verify("POST", "/v1/responses", h, p, body, key, now); e == nil || v != nil {
				t.Fatal("signed malformed context accepted")
			}
		})
	}
	other := dispatchtest.New(t)
	if v, e := other.Verifier.Verify("POST", "/v1/responses", header, proof, body, key, now); e == nil || v != nil {
		t.Fatal("untrusted public key accepted")
	}
	zero := new(metondispatch.Verified)
	if zero.Current(now) || zero.Current(time.Time{}) {
		t.Fatal("zero verified value accepted")
	}
	if v, e := metondispatch.NewVerifier("s2-isolated", "s2-managed", 1, nil); e == nil || v != nil {
		t.Fatal("missing gateway trust accepted")
	}
}

/** TestModelDispatchCSharpWire 使用同一 C# 产出的字节，不拿 Go 自签回环代替跨语言接缝。 */
func TestModelDispatchCSharpWire(t *testing.T) {
	raw, err := os.ReadFile(os.Getenv("METON_DISPATCH_WIRE"))
	if err != nil {
		t.Fatal(err)
	}
	var input struct {
		FormatVersion int    `json:"format_version"`
		Certificate   string `json:"certificate"`
		Samples       []struct {
			Path, Context, Proof, Body, Key string
			Now                             int64
		}
	}
	if json.Unmarshal(raw, &input) != nil || input.FormatVersion != 1 || len(input.Samples) != 2 {
		t.Fatal("missing cross-language samples")
	}
	der, err := base64.StdEncoding.DecodeString(input.Certificate)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	v, err := metondispatch.NewVerifier("s2-isolated", "s2-managed", 1, map[string]*x509.Certificate{"gateway-s2": cert})
	if err != nil {
		t.Fatal(err)
	}
	for _, sample := range input.Samples {
		body, err := base64.StdEncoding.DecodeString(sample.Body)
		if err != nil {
			t.Fatal(err)
		}
		now := time.Unix(sample.Now, 0)
		verified, err := v.Verify("POST", sample.Path, sample.Context, sample.Proof, body, []byte(sample.Key), now)
		if err != nil || verified == nil || verified.Context().KeyDigest != dispatchtest.Hash([]byte(sample.Key)) {
			t.Fatal("C# proof rejected", err)
		}
		if late, e := v.Verify("POST", sample.Path, sample.Context, sample.Proof, body, []byte(sample.Key), now.Add(5*time.Second)); e == nil || late != nil {
			t.Fatal("expired C# proof accepted")
		}
	}
}
