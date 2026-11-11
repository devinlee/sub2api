//go:build meton_managed

package metonentry

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

/** cashEnvironmentFrame 保留正式工具的有界帧格式，不经数据库或支付网络。 */
func cashEnvironmentFrame(t *testing.T, header any, sealed []byte) []byte {
	t.Helper()
	raw, err := json.Marshal(header)
	if err != nil {
		t.Fatal(err)
	}
	var buffer bytes.Buffer
	if err := binary.Write(&buffer, binary.BigEndian, uint32(len(raw))); err != nil {
		t.Fatal(err)
	}
	buffer.Write(raw)
	buffer.Write(sealed)
	return buffer.Bytes()
}

/** TestOriginalCashEnvironmentInspection 历史材料可验真但不能跨现金环境重绑，也不能成为当前执行或凭据。 */
func TestOriginalCashEnvironmentInspection(t *testing.T) {
	fail := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	keyBytes := []byte(base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{47}, 32)))
	key, err := parseCashRecoveryKey(keyBytes)
	fail(err)
	signing, err := rsa.GenerateKey(rand.Reader, 2048)
	fail(err)
	public, err := x509.MarshalPKIXPublicKey(&signing.PublicKey)
	fail(err)
	publicPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: public}))
	check := func(result CashNoticeInspection, err error, expected bool) {
		t.Helper()
		fail(err)
		if result.AllVerified != expected || expected && result.Verified != 1 || !expected && result.Verified != 0 ||
			result.ExecutionAuthorized || result.CredentialsRestored || result.FinancialCoverageVerified || result.DeletionAuthorized || result.FormalOpeningAuthorized {
			t.Fatal("原证明范围或只读权限不符")
		}
	}
	for _, environment := range []string{"isolated", "live"} {
		t.Run(environment, func(t *testing.T) {
			scope := CashNoticeInspectionScope{Environment: "s328-test", Source: "cash-original", Epoch: 1, SourceSystem: "123", InboxSystem: "456",
				Channel: "wechatpay", CashEnvironment: environment, Merchant: "12340001", App: "wx-local"}
			cfg := notificationConfig{Environment: scope.Environment, Source: scope.Source, Epoch: 1, SourceSystem: scope.SourceSystem, InboxSystem: scope.InboxSystem,
				KeyRef: "history-v1", Route: service.CheckoutPaymentRoute{Channel: scope.Channel, Environment: environment, Merchant: scope.Merchant, App: scope.App}}
			wire, err := json.Marshal(map[string]any{"deployment": cfg.Environment, "source": cfg.Source, "epoch": cfg.Epoch, "sourceSystem": cfg.SourceSystem,
				"inboxSystem": cfg.InboxSystem, "channel": cfg.Route.Channel, "cashEnvironment": environment, "merchant": cfg.Route.Merchant, "app": cfg.Route.App})
			fail(err)
			store := &cashNoticeStore{cfg: cfg, cipher: key, wire: wire}
			n := payment.CashNotice{Kind: "payment", Delivery: "original-payment", State: "SUCCESS", Merchant: scope.Merchant, App: scope.App, Order: "original-order",
				Transaction: "original-transaction", Total: 1031, PayerTotal: 1031, Currency: "CNY"}
			body := []byte(`{"original":"retained-notice-only"}`)
			headers := http.Header{"Wechatpay-Timestamp": []string{"946684800"}, "Wechatpay-Nonce": []string{"history-nonce"}}
			hash := sha256.Sum256([]byte(headers.Get("Wechatpay-Timestamp") + "\n" + headers.Get("Wechatpay-Nonce") + "\n" + string(body) + "\n"))
			signature, err := rsa.SignPKCS1v15(rand.Reader, signing, crypto.SHA256, hash[:])
			fail(err)
			headers.Set("Wechatpay-Signature", base64.StdEncoding.EncodeToString(signature))
			digest, sealed, err := store.sealPaymentProof("payment", n.Delivery, &n, []byte(`{"original":"no-execution"}`), body, headers, publicPEM, "")
			fail(err)
			input := cashNoticeInspectionInput{Version: 1, Kind: "meton.s3.cash-notice-inspection.v1", Scope: scope, Keys: map[string][]byte{"history-v1": keyBytes},
				Proofs: []CashNoticeProofHeader{{Kind: "payment", Delivery: n.Delivery, KeyRef: "history-v1", Digest: hex.EncodeToString(digest), Size: len(sealed)}}}
			r, e := InspectCashNoticeMaterials(bytes.NewReader(cashEnvironmentFrame(t, input, sealed)))
			check(r, e, true)
			other := "live"
			if environment == "live" {
				other = "isolated"
			}
			input.Scope.CashEnvironment = other
			r, e = InspectCashNoticeMaterials(bytes.NewReader(cashEnvironmentFrame(t, input, sealed)))
			check(r, e, false)
			input.Scope.CashEnvironment = "unknown"
			if _, e = InspectCashNoticeMaterials(bytes.NewReader(cashEnvironmentFrame(t, input, sealed))); e == nil {
				t.Fatal("未知现金环境未关闭")
			}

			ref, op := uuid.New(), uuid.New()
			route := cashReviewMaterialRoute{Deployment: scope.Environment, Source: scope.Source, Epoch: 1, KeyRef: uuid.New(), SourceSystem: scope.SourceSystem,
				InboxSystem: scope.InboxSystem, Channel: scope.Channel, CashEnvironment: environment, Merchant: scope.Merchant, App: scope.App}
			routeBytes, err := json.Marshal(route)
			fail(err)
			material := []byte("original payer verification; no payment authority")
			materialHash := sha256.Sum256(material)
			facts, err := json.Marshal(map[string]any{"format": 1, "refund": ref, "materialHash": hex.EncodeToString(materialHash[:])})
			fail(err)
			factsHash := sha256.Sum256(facts)
			aad, _, err := reviewMaterialAAD(payerReview, routeBytes, ref, op, "history-v1", hex.EncodeToString(factsHash[:]))
			fail(err)
			value, err := json.Marshal(map[string]any{"format_version": 1, "facts": string(facts), "material": material})
			fail(err)
			nonce := make([]byte, key.NonceSize())
			_, err = rand.Read(nonce)
			fail(err)
			reviewSealed := key.Seal(nonce, nonce, value, aad)
			proof := cashReviewProof{Kind: "payer", Reference: ref, Operation: op, KeyRef: "history-v1", Route: string(routeBytes), Facts: string(facts), Size: len(reviewSealed)}
			review := map[string]any{"format_version": 1, "kind": "meton.s3.cash-review-inspection.v1", "scope": scope, "keys": map[string][]byte{"history-v1": keyBytes}, "proofs": []cashReviewProof{proof}}
			r, e = InspectCashReviewMaterials(bytes.NewReader(cashEnvironmentFrame(t, review, reviewSealed)))
			check(r, e, true)
			scope.CashEnvironment = other
			review["scope"] = scope
			r, e = InspectCashReviewMaterials(bytes.NewReader(cashEnvironmentFrame(t, review, reviewSealed)))
			check(r, e, false)
		})
	}
}
