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

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
)

/** 并发重入统计来自实际 Once 拦截；原调用只领取一次、实际 HTTP 只发送一次。 */
func TestRejectionObservationActualConcurrentTransport(t *testing.T) {
	body, key := []byte(`{"input":"synthetic"}`), []byte("fixture-secret")
	c := dispatchtest.Context(body, key)
	verified := dispatchtest.New(t).Verify(t, c, body, key)
	observer, err := metonobserve.Install(metonobserve.Scope{Environment: c.Environment, Source: c.Source, Epoch: c.Epoch}, "one")
	if err != nil {
		t.Fatal(err)
	}
	defer observer.Close()
	var calls, claims atomic.Int64
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_, _ = io.Copy(io.Discard, r.Body)
		_ = r.Body.Close()
		_, _ = w.Write([]byte("synthetic"))
	}))
	defer upstream.Close()
	transport := http.DefaultTransport.(*http.Transport).Clone()
	defer transport.CloseIdleConnections()
	gate, err := metontransport.New(verified, func(context.Context) (bool, error) { claims.Add(1); return true, nil }, transport)
	if err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	for i := 0; i < 32; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			r, _ := http.NewRequestWithContext(t.Context(), "POST", upstream.URL, strings.NewReader(string(body)))
			response, _ := gate.RoundTrip(r)
			if response != nil {
				_, _ = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
			}
		}()
	}
	workers.Wait()
	s, ok := observer.Snapshot()
	if !ok || calls.Load() != 1 || claims.Load() != 1 || s.Counts[metonobserve.RepeatAttempt].Value != 31 {
		t.Fatal("counter changed execution", s, calls.Load(), claims.Load())
	}
	if s.Counts[metonobserve.SendNotGranted].Value != 0 || s.Counts[metonobserve.SendQueryFailed].Value != 0 {
		t.Fatal("transport inferred database decision")
	}
}

/** 首次未知不是重复；随后重入才计拦截，不能重新领取、派发或更改原返回。 */
func TestRejectionObservationUnknownThenRepeatedAttempt(t *testing.T) {
	body, key := []byte(`{"input":"synthetic"}`), []byte("fixture-secret")
	c := dispatchtest.Context(body, key)
	v := dispatchtest.New(t).Verify(t, c, body, key)
	observer, err := metonobserve.Install(metonobserve.Scope{Environment: c.Environment, Source: c.Source, Epoch: c.Epoch}, "one")
	if err != nil {
		t.Fatal(err)
	}
	defer observer.Close()
	var claims, calls int
	gate, err := metontransport.New(v, func(context.Context) (bool, error) { claims++; return false, errors.New("unconfirmed") }, roundTripper(func(*http.Request) (*http.Response, error) { calls++; return nil, errors.New("unexpected") }))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		r, _ := http.NewRequestWithContext(t.Context(), "POST", "http://unused.invalid", strings.NewReader(string(body)))
		if response, e := gate.RoundTrip(r); e == nil || response != nil {
			t.Fatal("unknown became success")
		}
		s, _ := observer.Snapshot()
		if s.Counts[metonobserve.RepeatAttempt].Value != uint64(i) {
			t.Fatal("initial unknown counted as duplicate")
		}
	}
	if claims != 1 || calls != 0 {
		t.Fatal("unknown retried")
	}
}
