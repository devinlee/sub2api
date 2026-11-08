//go:build meton_managed && dispatch_integration

package metontransport_test

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
)

type roundTripper func(*http.Request) (*http.Response, error)

func (r roundTripper) RoundTrip(q *http.Request) (*http.Response, error) { return r(q) }

/** TestModelDispatchActualHTTP 逐次计数实际 HTTP，拒绝供应重试、重定向和断流后的第二次尝试。 */
func TestModelDispatchActualHTTP(t *testing.T) {
	signer := dispatchtest.New(t)
	body, key := []byte(`{"input":"synthetic"}`), []byte("synthetic-key")
	for _, mode := range []string{"success", "server-error", "redirect", "connection-lost"} {
		t.Run(mode, func(t *testing.T) {
			var calls, claims, redirects atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/redirected" {
					redirects.Add(1)
					w.WriteHeader(200)
					return
				}
				calls.Add(1)
				if r.Header.Get(metondispatch.ContextHeader) != "" || r.Header.Get(metondispatch.ProofHeader) != "" || r.Header.Get("Idempotency-Key") != "" {
					t.Error("internal header reached upstream")
				}
				_, _ = io.Copy(io.Discard, r.Body)
				_ = r.Body.Close()
				switch mode {
				case "redirect":
					w.Header().Set("Location", "/redirected")
					w.WriteHeader(307)
				case "server-error":
					w.WriteHeader(500)
				case "connection-lost":
					connection, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					_ = connection.Close()
				default:
					w.WriteHeader(200)
					_, _ = w.Write([]byte("synthetic"))
				}
			}))
			defer server.Close()
			base := http.DefaultTransport.(*http.Transport).Clone()
			defer base.CloseIdleConnections()
			v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
			gate, err := metontransport.New(v, func(context.Context) (bool, error) { claims.Add(1); return true, nil }, roundTripper(func(r *http.Request) (*http.Response, error) {
				if r.GetBody != nil {
					t.Error("transport retains replayable body")
				}
				return base.RoundTrip(r)
			}))
			if err != nil {
				t.Fatal(err)
			}
			client := &http.Client{Transport: gate, Timeout: time.Second}
			for attempt := 0; attempt < 3; attempt++ {
				request, err := http.NewRequestWithContext(t.Context(), "POST", server.URL+"/model", strings.NewReader(string(body)))
				if err != nil {
					t.Fatal(err)
				}
				request.Header.Set(metondispatch.ContextHeader, "must-not-forward")
				request.Header.Set(metondispatch.ProofHeader, "must-not-forward")
				request.Header.Set("Idempotency-Key", "retry-trigger")
				response, e := client.Do(request)
				if response != nil {
					_, _ = io.Copy(io.Discard, response.Body)
					_ = response.Body.Close()
				}
				if attempt > 0 && e == nil {
					t.Fatal("repeat dispatch reached network")
				}
			}
			if calls.Load() != 1 || claims.Load() != 1 || redirects.Load() != 0 {
				t.Fatalf("calls=%d claims=%d redirects=%d", calls.Load(), claims.Load(), redirects.Load())
			}
		})
	}
}

/** TestModelDispatchNoPermit 领取结果未知、撤销或过期都不能调用实际传输，也不能重复领取。 */
func TestModelDispatchNoPermit(t *testing.T) {
	signer := dispatchtest.New(t)
	body, key := []byte(`{"input":"test"}`), []byte("synthetic-key")
	for _, mode := range []string{"unknown", "already-claimed", "cancel-after-claim", "expire-after-claim"} {
		t.Run(mode, func(t *testing.T) {
			var calls, claims atomic.Int32
			c := dispatchtest.Context(body, key)
			if mode == "expire-after-claim" {
				c.ValidUntilMS = time.Now().Add(120 * time.Millisecond).UnixMilli()
			}
			v := signer.Verify(t, c, body, key)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			gate, err := metontransport.New(v, func(context.Context) (bool, error) {
				claims.Add(1)
				switch mode {
				case "unknown":
					return false, errors.New("commit response lost")
				case "already-claimed":
					return false, nil
				case "cancel-after-claim":
					cancel()
				case "expire-after-claim":
					time.Sleep(160 * time.Millisecond)
				}
				return true, nil
			}, roundTripper(func(r *http.Request) (*http.Response, error) {
				calls.Add(1)
				_ = r.Body.Close()
				return nil, errors.New("unexpected wire")
			}))
			if err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 2; i++ {
				request, _ := http.NewRequestWithContext(ctx, "POST", "http://unused.invalid/", strings.NewReader(string(body)))
				if _, e := gate.RoundTrip(request); e == nil {
					t.Fatal("unconfirmed dispatch accepted")
				}
			}
			if calls.Load() != 0 || claims.Load() != 1 {
				t.Fatal("unknown claim retried or sent")
			}
		})
	}
	if gate, err := metontransport.New(new(metondispatch.Verified), func(context.Context) (bool, error) { return true, nil }, http.DefaultTransport); err == nil || gate != nil {
		t.Fatal("query-like zero proof grants a send")
	}
}

/** TestModelDispatchConcurrentAttempts 同一进程中的并发调用也只有一方能触碰领取端口。 */
func TestModelDispatchConcurrentAttempts(t *testing.T) {
	signer := dispatchtest.New(t)
	body, key := []byte(`{"input":"test"}`), []byte("synthetic-key")
	v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
	var claims, calls atomic.Int32
	gate, err := metontransport.New(v, func(context.Context) (bool, error) { claims.Add(1); return true, nil }, roundTripper(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		_ = r.Body.Close()
		return nil, errors.New("lost after send")
	}))
	if err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	for i := 0; i < 16; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			r, _ := http.NewRequestWithContext(t.Context(), "POST", "http://unused.invalid/", strings.NewReader(string(body)))
			_, _ = gate.RoundTrip(r)
		}()
	}
	workers.Wait()
	if claims.Load() != 1 || calls.Load() != 1 {
		t.Fatal("concurrent sender duplicated")
	}
}
