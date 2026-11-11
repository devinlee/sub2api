package provider

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
)

// IsolatedAlternativeCash 的网络目标只能是显式回环地址；它不是微信官方替代退款接口。
type IsolatedAlternativeCash struct {
	endpoint string
	merchant string
	signer   ed25519.PrivateKey
	verifier ed25519.PublicKey
	client   *http.Client
}

/** NewIsolatedAlternativeCash 禁止代理、跳转和自动 POST 重试；真实渠道必须另有明确的协议适配。 */
func NewIsolatedAlternativeCash(endpoint, merchant string, signer ed25519.PrivateKey, verifier ed25519.PublicKey) (*IsolatedAlternativeCash, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "http" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" ||
		u.Port() == "" || net.ParseIP(u.Hostname()) == nil || !net.ParseIP(u.Hostname()).IsLoopback() ||
		len(signer) != ed25519.PrivateKeySize || len(verifier) != ed25519.PublicKeySize || merchant == "" {
		return nil, payment.ErrInvalidCashNotice
	}
	return &IsolatedAlternativeCash{endpoint: endpoint, merchant: merchant, signer: append(ed25519.PrivateKey(nil), signer...), verifier: append(ed25519.PublicKey(nil), verifier...),
		client: &http.Client{Timeout: 8 * time.Second, Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true, DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

/** SendAlternativeCash 仅提交原业务号；成功应答仍须原号查询才能转为现金成功事实。 */
func (p *IsolatedAlternativeCash) SendAlternativeCash(ctx context.Context, target payment.AlternativeCashTarget) (*payment.AlternativeCashProof, error) {
	return p.exchange(ctx, http.MethodPost, target)
}

/** QueryAlternativeCash 只查询原业务号，不在查无或未知时重新提交付款。 */
func (p *IsolatedAlternativeCash) QueryAlternativeCash(ctx context.Context, target payment.AlternativeCashTarget) (*payment.AlternativeCashProof, error) {
	return p.exchange(ctx, http.MethodGet, target)
}

/** CloseAlternativeCash 只关闭原业务号。此模拟协议保证关闭后不能再付款，关闭应答仍须 GET 复核。 */
func (p *IsolatedAlternativeCash) CloseAlternativeCash(ctx context.Context, target payment.AlternativeCashTarget) (*payment.AlternativeCashProof, error) {
	return p.exchange(ctx, "CLOSE", target)
}

/** exchange 从原字节验签，核对挑战及完整付款目标后才交出受信事实。 */
func (p *IsolatedAlternativeCash) exchange(ctx context.Context, method string, target payment.AlternativeCashTarget) (*payment.AlternativeCashProof, error) {
	bad := payment.ErrInvalidCashNotice
	if !target.Valid() || target.Merchant != p.merchant {
		return nil, bad
	}
	path := "/transfers/" + url.PathEscape(target.Order)
	if method == "CLOSE" {
		method = http.MethodPost
		path += "/close"
	}
	var body []byte
	if method == http.MethodPost {
		body, _ = json.Marshal(target)
	}
	r, err := http.NewRequestWithContext(ctx, method, p.endpoint+path, bytes.NewReader(body))
	if err != nil {
		return nil, bad
	}
	// Transport 仅可能安全重试无副作用 GET；POST 不设置幂等头且不提供重建 body 的函数。
	r.GetBody = nil
	nonce := make([]byte, 24)
	if _, err = rand.Read(nonce); err != nil {
		return nil, bad
	}
	challenge := hex.EncodeToString(nonce)
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Meton-Nonce", challenge)
	r.Header.Set("X-Meton-Time", stamp)
	r.Header.Set("X-Meton-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(p.signer, payment.AlternativeCashStatement("request", method, path, challenge, stamp, 0, body))))
	res, err := p.client.Do(r)
	if err != nil {
		return nil, bad
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 65537))
	if err != nil || len(raw) > 65536 || res.StatusCode != http.StatusOK {
		return nil, bad
	}
	responseTime := res.Header.Get("X-Meton-Time")
	timestamp, err := strconv.ParseInt(responseTime, 10, 64)
	if err != nil || res.Header.Get("X-Meton-Nonce") != challenge || time.Since(time.Unix(timestamp, 0)) > 5*time.Minute || time.Until(time.Unix(timestamp, 0)) > time.Minute {
		return nil, bad
	}
	statement := payment.AlternativeCashStatement("response", method, path, challenge, responseTime, res.StatusCode, raw)
	sig, err := base64.StdEncoding.DecodeString(res.Header.Get("X-Meton-Signature"))
	if err != nil || !ed25519.Verify(p.verifier, statement, sig) {
		return nil, bad
	}
	var fact payment.AlternativeCashFact
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&fact) != nil || d.Decode(new(any)) != io.EOF || !fact.Valid() || fact.Payment != target {
		return nil, bad
	}
	return &payment.AlternativeCashProof{Fact: fact, Raw: raw, Statement: statement, Signature: sig, PublicKey: append([]byte(nil), p.verifier...)}, nil
}
