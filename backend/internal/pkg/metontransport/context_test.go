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

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
)

/** 多个账户客户端及 WithoutCancel 仍共享原资格，不能靠重新包装连接池多次领取。 */
func TestModelDispatchBoundClients(t *testing.T) {
	signer := dispatchtest.New(t)
	body, key := []byte(`{"input":"synthetic"}`), []byte("synthetic-key")
	v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
	var claims, calls atomic.Int32
	ctx, err := metontransport.Bind(t.Context(), v, func(context.Context) (bool, error) { claims.Add(1); return true, nil })
	if err != nil {
		t.Fatal(err)
	}
	if _, err = metontransport.Bind(ctx, v, func(context.Context) (bool, error) { return true, nil }); err == nil {
		t.Fatal("rebound original")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Meton-Service-Proof") != "" || r.Header.Get("Idempotency-Key") != "" {
			t.Error("private header leaked")
		}
		_, _ = io.Copy(io.Discard, r.Body)
		_ = r.Body.Close()
		_, _ = w.Write([]byte("synthetic"))
	}))
	defer server.Close()
	var workers sync.WaitGroup
	for i := 0; i < 8; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			transport := http.DefaultTransport.(*http.Transport).Clone()
			defer transport.CloseIdleConnections()
			for retry := 0; retry < 2; retry++ {
				r, _ := http.NewRequestWithContext(context.WithoutCancel(ctx), "POST", server.URL, strings.NewReader(string(body)))
				r.Header["meton-service-proof"] = []string{"must-not-forward"}
				r.Header["idempotency-key"] = []string{"retry-trigger"}
				client, e := metontransport.Client(&http.Client{Transport: transport}, r)
				if e != nil {
					t.Error(e)
					return
				}
				response, _ := client.Do(r)
				if response != nil {
					_, _ = io.Copy(io.Discard, response.Body)
					_ = response.Body.Close()
				}
			}
		}()
	}
	workers.Wait()
	if calls.Load() != 1 || claims.Load() != 1 {
		t.Fatalf("calls=%d claims=%d", calls.Load(), claims.Load())
	}
	wrapped := roundTripper(func(*http.Request) (*http.Response, error) {
		t.Error("unknown retry wrapper ran")
		return nil, errors.New("unexpected")
	})
	r, _ := http.NewRequestWithContext(ctx, "POST", server.URL, strings.NewReader(string(body)))
	if _, err = metontransport.Client(&http.Client{Transport: wrapped}, r); err == nil {
		t.Fatal("accepted unbounded transport")
	}
}

/** 原请求取消不被原生脱离上下文绕过；即使上游已开始响应，取消仍到达真实连接。 */
func TestModelDispatchDetachedCancellation(t *testing.T) {
	signer := dispatchtest.New(t)
	body, key := []byte(`{"input":"synthetic"}`), []byte("synthetic-key")
	for _, phase := range []string{"before-claim", "during-claim", "during-response"} {
		t.Run(phase, func(t *testing.T) {
			original, cancel := context.WithCancel(t.Context())
			defer cancel()
			v := signer.Verify(t, dispatchtest.Context(body, key), body, key)
			var claims, calls atomic.Int32
			stopped := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				_, _ = io.Copy(io.Discard, r.Body)
				_ = r.Body.Close()
				w.WriteHeader(200)
				_, _ = w.Write([]byte("first"))
				w.(http.Flusher).Flush()
				<-r.Context().Done()
				close(stopped)
			}))
			defer server.Close()
			ctx, err := metontransport.Bind(original, v, func(context.Context) (bool, error) {
				claims.Add(1)
				if phase == "during-claim" {
					cancel()
				}
				return true, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			if phase == "before-claim" {
				cancel()
			}
			transport := http.DefaultTransport.(*http.Transport).Clone()
			defer transport.CloseIdleConnections()
			r, _ := http.NewRequestWithContext(context.WithoutCancel(ctx), "POST", server.URL, strings.NewReader(string(body)))
			client, err := metontransport.Client(&http.Client{Transport: transport, Timeout: 3 * time.Second}, r)
			if phase == "before-claim" {
				if err == nil {
					t.Fatal("cancelled admission accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			response, err := client.Do(r)
			if phase == "during-claim" {
				if err == nil || response != nil || calls.Load() != 0 || claims.Load() != 1 {
					t.Fatal("cancel after claim dispatched")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			cancel()
			_, err = io.ReadAll(response.Body)
			_ = response.Body.Close()
			if err == nil {
				t.Fatal("detached stream survived original cancel")
			}
			select {
			case <-stopped:
			case <-time.After(2 * time.Second):
				t.Fatal("upstream was not cancelled")
			}
			if calls.Load() != 1 || claims.Load() != 1 {
				t.Fatal("unexpected repeated request")
			}
		})
	}
}
