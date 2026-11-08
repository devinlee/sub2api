//go:build meton_managed && dispatch_integration

package metontransport_test

import (
	"context"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

/** TestOriginalProviderTransport 核对实际发送者，而非最后构造的客户端或用户伪造头。 */
func TestOriginalProviderTransport(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_, _ = io.Copy(io.Discard, r.Body)
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()
	body, key := []byte(`{"input":"synthetic"}`), []byte("synthetic-key")
	signer := dispatchtest.New(t)
	v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
	captured := int64(0)
	ctx, e := metontransport.BindPrepared(t.Context(), v, func(ctx context.Context, r *http.Request, actual []byte) (bool, error) {
		captured = metontransport.ProviderAccount(ctx)
		if r.Header.Get("X-Provider-Account") != "999" || string(actual) != string(body) {
			t.Fatal("原请求被改写")
		}
		return true, nil
	})
	if e != nil {
		t.Fatal(e)
	}
	request, _ := http.NewRequestWithContext(ctx, "POST", server.URL, strings.NewReader(string(body)))
	request.Header.Set("X-Provider-Account", "999")
	client, e := metontransport.ClientForProvider(server.Client(), request, 23)
	if e != nil {
		t.Fatal(e)
	}
	other, e := metontransport.ClientForProvider(server.Client(), request, 47)
	if e != nil {
		t.Fatal(e)
	}
	response, e := client.Do(request)
	if e != nil {
		t.Fatal(e)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	_ = response.Body.Close()
	retry, _ := http.NewRequestWithContext(ctx, "POST", server.URL, strings.NewReader(string(body)))
	if _, e = other.Do(retry); e == nil || captured != 23 || calls.Load() != 1 {
		t.Fatal("原供应绑定被替换或重复发送", captured, calls.Load(), e)
	}
	if _, e = metontransport.ClientForProvider(server.Client(), request, 0); e == nil {
		t.Fatal("供应账户缺失仍装配")
	}
}
