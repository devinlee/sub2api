//go:build meton_managed && dispatch_integration

package metonledger

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
	native "github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

/** TestModelTransportPostgres 经过来源事务和实际 HTTP 计数，覆盖多个独立发送对象及丢失提交回应。 */
func TestModelTransportPostgres(t *testing.T) {
	testModelTransportPostgres(t, false)
}

/** 使用同一来源事务联通原生 HTTPUpstream，换原生账户与重新建客户端不能再领一次发送。 */
func TestModelNativeTransportPostgres(t *testing.T) {
	testModelTransportPostgres(t, true)
}

func testModelTransportPostgres(t *testing.T, nativeTransport bool) {
	t.Setenv("METON_MANAGED_FUNDS_MODE", "s2-source-v1")
	t.Setenv("METON_MANAGED_ENVIRONMENT", "s2-isolated")
	t.Setenv("METON_MANAGED_SOURCE", "s2-managed")
	t.Setenv("METON_MANAGED_EPOCH", "1")
	var fixtures []struct {
		Context metondispatch.Context
		Key     SessionKey
		Secret  string
	}
	fixtureName := "METON_TRANSPORT_FIXTURE"
	if nativeTransport {
		fixtureName = "METON_NATIVE_TRANSPORT_FIXTURE"
	}
	raw, err := os.ReadFile(os.Getenv(fixtureName))
	if err != nil {
		t.Fatal(err)
	}
	if json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 3 {
		t.Fatal("missing source fixture")
	}
	open := func(role string) *TextLedger {
		db, e := sql.Open("postgres", "host=127.0.0.1 port=5432 dbname=s2_grants sslmode=disable user="+role)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { _ = db.Close() })
		l, e := NewTextLedger(db)
		if e != nil {
			t.Fatal(e)
		}
		return l
	}
	writer, sender, reader, closer := open("s2_transport_reserve"), open("s2_transport_send"), open("s2_read"), open("s2_cancel")
	signer := dispatchtest.New(t)
	body := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic"}`)
	for i, name := range []string{"concurrent", "cancelled-unsent", "unknown-claim"} {
		t.Run(name, func(t *testing.T) {
			f := fixtures[i]
			c := f.Context
			if nativeTransport {
				c.OperationID = uuid.NewString()
			}
			c.InputDigest = dispatchtest.Hash(body)
			c.ValidUntilMS = time.Now().Add(25 * time.Second).UnixMilli()
			v := signer.Verify(t, c, body, []byte(f.Secret))
			estimate := Estimate{Protocol: c.Protocol, Model: c.Model, Digest: c.InputDigest, DigestVersion: 1, InputBound: 2, OutputBound: 1}
			hold, e := writer.ReserveTransport(t.Context(), v, f.Key, estimate)
			if e != nil {
				t.Fatal(e)
			}
			call := Call{User: c.User, Account: c.Account, SourceMarker: hold.Origin.SourceMarker, Caller: c.Caller, OperationID: c.OperationID}
			if hold.State != "prepared" || hold.Quote != "3.00000000" {
				t.Fatal("wrong initial hold")
			}
			if h, e := reader.ReserveTransport(t.Context(), v, f.Key, estimate); e == nil || h != nil {
				t.Fatal("reader can reserve")
			}
			if h, e := writer.Reserve(t.Context(), call, f.Key, estimate); e == nil || h != nil {
				t.Fatal("transport writer bypasses trusted admission")
			}
			if ok, e := sender.ClaimDispatch(t.Context(), call, hold.Origin.SourceRequestID, f.Key); e == nil || ok {
				t.Fatal("transport sender bypasses original sender proof")
			}
			if name == "cancelled-unsent" {
				cancelled, e := closer.CancelUnsent(t.Context(), call, hold.Origin.SourceRequestID)
				if e != nil || cancelled.State != "cancelled_unsent" {
					t.Fatal("cancel failed", e)
				}
			}
			var calls, permits atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				_, _ = io.Copy(io.Discard, r.Body)
				_ = r.Body.Close()
				_, _ = w.Write([]byte("synthetic"))
			}))
			defer upstream.Close()
			transport := http.DefaultTransport.(*http.Transport).Clone()
			defer transport.CloseIdleConnections()
			var workers sync.WaitGroup
			for n := 0; n < 8; n++ {
				workers.Add(1)
				go func() {
					defer workers.Done()
					replayed, e := writer.ReserveTransport(t.Context(), v, f.Key, estimate)
					if e != nil || replayed.Origin.SourceRequestID != hold.Origin.SourceRequestID {
						t.Error("admission replay differs", e)
						return
					}
					claim := func(ctx context.Context) (bool, error) {
						first, e := sender.ClaimTransport(ctx, v, f.Key, replayed)
						if first {
							permits.Add(1)
							if name == "unknown-claim" {
								return false, errors.New("lost commit observation")
							}
						}
						return first, e
					}
					gate, e := metontransport.New(v, claim, transport)
					if e != nil {
						t.Error(e)
						return
					}
					client := &http.Client{Transport: gate, Timeout: 3 * time.Second}
					bound, e := metontransport.Bind(t.Context(), v, claim)
					if e != nil {
						t.Error(e)
						return
					}
					nativeClient := native.NewHTTPUpstream(nil)
					for retry := 0; retry < 2; retry++ {
						request, e := http.NewRequestWithContext(context.WithoutCancel(bound), "POST", upstream.URL, strings.NewReader(string(body)))
						if e != nil {
							t.Error(e)
							return
						}
						var response *http.Response
						if nativeTransport {
							response, _ = nativeClient.Do(request, "", int64(retry+1), 1)
						} else {
							response, _ = client.Do(request)
						}
						if response != nil {
							_, _ = io.Copy(io.Discard, response.Body)
							_ = response.Body.Close()
						}
					}
				}()
			}
			workers.Wait()
			wantCalls, wantPermits := int32(0), int32(1)
			if name == "concurrent" {
				wantCalls = 1
			}
			if name == "cancelled-unsent" {
				wantPermits = 0
			}
			if calls.Load() != wantCalls || permits.Load() != wantPermits {
				t.Fatalf("calls=%d permits=%d", calls.Load(), permits.Load())
			}
			found, e := reader.Find(t.Context(), call)
			if e != nil {
				t.Fatal(e)
			}
			expected := "dispatch_claimed"
			if name == "cancelled-unsent" {
				expected = "cancelled_unsent"
			}
			if found.State != expected || found.Origin.SourceRequestID != hold.Origin.SourceRequestID {
				t.Fatal("original state changed")
			}
			if first, e := sender.ClaimTransport(t.Context(), v, f.Key, found); e != nil || first {
				t.Fatal("read receipt grants another send", e)
			}
			changed := c
			changed.Worker = fixtures[(i+1)%3].Context.Worker
			other := signer.Verify(t, changed, body, []byte(f.Secret))
			if h, e := writer.ReserveTransport(t.Context(), other, f.Key, estimate); e == nil || h != nil {
				t.Fatal("new sender replaces original")
			}
		})
	}
}
