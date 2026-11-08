//go:build meton_managed && dispatch_integration

package metontransport_test

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
)

/** 预占看到真正出站快照；回调改写副本和未知后重试都不能改变网络内容或次数。 */
func TestModelDispatchPreparedSnapshot(t *testing.T) {
	signer := dispatchtest.New(t)
	body := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic"}`)
	key := []byte("synthetic")
	v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
	for _, mode := range []string{"success", "unknown", "cancelled", "wrong-length"} {
		t.Run(mode, func(t *testing.T) {
			var prepared, calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				actual, _ := io.ReadAll(r.Body)
				if string(actual) != string(body) || r.Header.Get("X-Changed") != "" {
					t.Error("snapshot changed after reservation")
				}
				_, _ = w.Write([]byte("ok"))
			}))
			defer server.Close()
			original, cancel := context.WithCancel(t.Context())
			defer cancel()
			ctx, e := metontransport.BindAuthenticated(original, v, metontransport.Subject{User: 1, Key: 2, Group: 3}, func(_ context.Context, r *http.Request, actual []byte) (bool, error) {
				prepared.Add(1)
				if string(actual) != string(body) || r.URL.String() != server.URL {
					t.Error("wrong actual request")
				}
				r.Header.Set("X-Changed", "true")
				r.URL.Host = "not-sent.invalid"
				actual[0] = 'x'
				if mode == "unknown" {
					return false, errors.New("commit observation lost")
				}
				if mode == "cancelled" {
					cancel()
				}
				return true, nil
			})
			if e != nil {
				t.Fatal(e)
			}
			if !metontransport.Admitted(ctx, metontransport.Subject{User: 1, Key: 2, Group: 3}) || metontransport.Admitted(ctx, metontransport.Subject{User: 4, Key: 2, Group: 3}) {
				t.Fatal("admission changed native owner")
			}
			transport := http.DefaultTransport.(*http.Transport).Clone()
			defer transport.CloseIdleConnections()
			for retry := 0; retry < 3; retry++ {
				r, _ := http.NewRequestWithContext(context.WithoutCancel(ctx), "POST", server.URL, strings.NewReader(string(body)))
				if mode == "wrong-length" {
					r.ContentLength++
				}
				client, err := metontransport.Client(&http.Client{Transport: transport}, r)
				if err == nil {
					response, _ := client.Do(r)
					if response != nil {
						_, _ = io.Copy(io.Discard, response.Body)
						_ = response.Body.Close()
					}
				}
			}
			wantCalls, wantPrepared := int32(0), int32(1)
			if mode == "success" {
				wantCalls = 1
			}
			if mode == "wrong-length" {
				wantPrepared = 0
			}
			if calls.Load() != wantCalls || prepared.Load() != wantPrepared {
				t.Fatalf("network=%d preparation=%d", calls.Load(), prepared.Load())
			}
		})
	}
}
