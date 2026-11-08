//go:build meton_managed && dispatch_integration && unit

package metonentry_test

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	"github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/lib/pq"
)

type completionConnector struct {
	driver.Connector
	writes, reads       atomic.Int32
	loseWrite, loseRead bool
}
type completionConnection struct {
	driver.Conn
	owner *completionConnector
}

func (c *completionConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return &completionConnection{conn, c}, nil
}

/** 先实际提交并读完数据库响应，再模拟回执丢失；不返回 ErrBadConn，避免驱动自身重跑语句。 */
func (c *completionConnection) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	write := strings.Contains(query, "meton_ledger.complete_execution_text(")
	read := strings.Contains(query, "meton_ledger.find_execution_result(")
	if write {
		c.owner.writes.Add(1)
	}
	if read {
		c.owner.reads.Add(1)
		if c.owner.loseRead {
			return nil, io.ErrUnexpectedEOF
		}
	}
	rows, err := c.Conn.(driver.QueryerContext).QueryContext(ctx, query, args)
	if err != nil || !write || !c.owner.loseWrite {
		return rows, err
	}
	values := make([]driver.Value, len(rows.Columns()))
	for {
		if e := rows.Next(values); e != nil {
			if e != io.EOF {
				_ = rows.Close()
				return nil, e
			}
			break
		}
	}
	if err = rows.Close(); err != nil {
		return nil, err
	}
	return nil, io.ErrUnexpectedEOF
}

func completionPool(t *testing.T, role string, loseWrite, loseRead bool) (*metonledger.TextLedger, *completionConnector) {
	t.Helper()
	base, err := pq.NewConnector("host=127.0.0.1 port=5432 dbname=s2_grants sslmode=disable user=" + role)
	if err != nil {
		t.Fatal(err)
	}
	connector := &completionConnector{Connector: base, loseWrite: loseWrite, loseRead: loseRead}
	db := sql.OpenDB(connector)
	t.Cleanup(func() { _ = db.Close() })
	return ledger(t, db), connector
}

/** 真实来源认证、预占、出站观察和结算；故障落在提交之后与查询之前，不能用进程内假余额代替。 */
func TestModelExecutionCompletionPostgres(t *testing.T) {
	for key, value := range map[string]string{"FUNDS_MODE": "s2-source-v1", "ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1",
		"CREATE_KEY_ID": strings.Repeat("1", 24), "READ_KEY_ID": strings.Repeat("2", 24), "ISSUE_KEY_ID": strings.Repeat("3", 24), "INSPECT_KEY_ID": strings.Repeat("4", 24)} {
		t.Setenv("METON_MANAGED_"+key, value)
	}
	var fixtures []struct {
		Context metondispatch.Context
		Key     metonledger.SessionKey
		Secret  string
		Group   int64
	}
	raw, err := os.ReadFile(os.Getenv("METON_COMPLETION_PORT_FIXTURE"))
	if err != nil || json.Unmarshal(raw, &fixtures) != nil || len(fixtures) != 5 {
		t.Fatal("missing completion fixture")
	}
	authDB, admin := connection(t, "s2_entry_auth"), connection(t, "postgres")
	client := ent.NewClient(ent.Driver(entsql.OpenDB(dialect.Postgres, authDB)))
	keys := service.NewAPIKeyService(repository.NewAPIKeyRepository(client, authDB), nil, nil, nil, nil, nil, nil)
	t.Cleanup(keys.StopAuthCacheInvalidationSubscriber)
	groups := repository.NewGroupRepository(client, authDB)
	reserve, send := ledger(t, connection(t, "s2_execution_reserve")), ledger(t, connection(t, "s2_execution_send"))
	signer := dispatchtest.New(t)
	for i, mode := range []string{"lost-receipt", "rollback", "disconnect", "key-revoked", "lost-and-read-down"} {
		t.Run(mode, func(t *testing.T) {
			f := fixtures[i]
			complete, writes := completionPool(t, "s2_execution_complete", mode == "lost-receipt" || mode == "lost-and-read-down", false)
			inspect, reads := completionPool(t, "s2_execution_result_read", false, mode == "lost-and-read-down")
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				_, _ = io.Copy(io.Discard, r.Body)
				_ = r.Body.Close()
				w.Header().Set("Content-Type", "text/event-stream")
				if mode == "disconnect" {
					w.Header().Set("Content-Length", "9999")
					_, _ = io.WriteString(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"未完\"}\n\n")
					return
				}
				if mode == "key-revoked" {
					if _, e := admin.Exec("UPDATE api_keys SET status='inactive' WHERE id=$1", f.Key.ID); e != nil {
						t.Error(e)
					}
				}
				_, _ = io.WriteString(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-completion\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"meton-s2-text-fixture\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0}}}}\n\n")
			}))
			defer upstream.Close()
			profile, err := metonexecution.NewFixtureProfile(metonexecution.Spec{Version: "completion-v1", Protocol: "responses", Model: "meton-s2-text-fixture", WireProtocol: "responses", WireModel: "meton-s2-text-fixture", Target: upstream.URL + "/v1/responses", MaxBodyBytes: 256 * 1024, InputWindow: 2, OutputWindow: 1})
			if err != nil {
				t.Fatal(err)
			}
			entry, err := metonentry.New(signer.Verifier, keys, groups, reserve, send, complete, inspect, []metonentry.Route{{Group: f.Group, Profiles: []*metonexecution.Profile{profile}}})
			if err != nil {
				t.Fatal(err)
			}
			body := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic","stream":true}`)
			c := f.Context
			c.InputDigest = dispatchtest.Hash(body)
			c.ValidUntilMS = time.Now().Add(25 * time.Second).UnixMilli()
			header, proof := signer.Encode(t, c, "/v1/responses", time.Now())
			if mode == "rollback" {
				_, err = admin.Exec("CREATE FUNCTION public.completion_entry_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF EXISTS(SELECT FROM meton_ledger.text_requests WHERE request_id=NEW.request_id AND operation_id=TG_ARGV[0]::uuid) THEN RAISE EXCEPTION 'synthetic before end'; END IF; RETURN NEW; END $$; CREATE TRIGGER completion_entry_fault BEFORE INSERT ON meton_ledger.text_fee_endings FOR EACH ROW EXECUTE FUNCTION public.completion_entry_fault('" + c.OperationID + "')")
				if err != nil {
					t.Fatal(err)
				}
			}
			invoke := func() error {
				incoming, _ := http.NewRequest("POST", "http://source.invalid/v1/responses", bytes.NewReader(body))
				incoming.Header.Set("Content-Type", "application/json")
				incoming.Header.Set("Authorization", "Bearer "+f.Secret)
				incoming.Header.Set(metondispatch.ContextHeader, header)
				incoming.Header.Set(metondispatch.ProofHeader, proof)
				accepted, _, e := entry.Admit(incoming)
				if e != nil {
					return e
				}
				out, _ := http.NewRequestWithContext(accepted.Context(), "POST", upstream.URL+"/v1/responses", bytes.NewReader(body))
				out.Header.Set("Content-Type", "application/json")
				transport := http.DefaultTransport.(*http.Transport).Clone()
				defer transport.CloseIdleConnections()
				network, e := metontransport.Client(&http.Client{Transport: transport}, out)
				if e != nil {
					return e
				}
				response, e := network.Do(out)
				if e != nil {
					return e
				}
				defer response.Body.Close()
				_, e = io.ReadAll(response.Body)
				return e
			}
			err = invoke()
			if mode == "disconnect" {
				if !errors.Is(err, io.ErrUnexpectedEOF) {
					t.Fatal("missing actual read failure", err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			wantRead := int32(0)
			if mode == "lost-receipt" || mode == "rollback" || mode == "lost-and-read-down" {
				wantRead = 1
			}
			if writes.writes.Load() != 1 || reads.reads.Load() != wantRead {
				t.Fatal("write was retried or query boundary changed", writes.writes.Load(), reads.reads.Load())
			}
			if mode == "rollback" {
				if _, err = admin.Exec("DROP TRIGGER completion_entry_fault ON meton_ledger.text_fee_endings; DROP FUNCTION public.completion_entry_fault()"); err != nil {
					t.Fatal(err)
				}
			}
			if err = invoke(); err == nil {
				t.Fatal("original request was dispatched again")
			}
			if calls.Load() != 1 || writes.writes.Load() != 1 || reads.reads.Load() != wantRead {
				t.Fatal("retry generated or charged again")
			}
			var balance, held string
			var completions, fees int
			if err = admin.QueryRow(`SELECT sum(l.remaining)::text,sum(l.held)::text FROM meton_ledger.lots l JOIN meton_ledger.events e ON e.event_id=l.credit_event JOIN public.meton_managed_creations m USING(source_marker) WHERE m.meton_user=$1`, c.User).Scan(&balance, &held); err != nil {
				t.Fatal(err)
			}
			if err = admin.QueryRow(`SELECT (SELECT count(*) FROM meton_ledger.text_completions x JOIN meton_ledger.text_requests r USING(request_id) WHERE r.operation_id=$1),(SELECT count(*) FROM meton_ledger.text_fee_reports f JOIN meton_ledger.text_requests r USING(request_id) WHERE r.operation_id=$1)`, c.OperationID).Scan(&completions, &fees); err != nil {
				t.Fatal(err)
			}
			wantBalance, wantHeld, wantCompletions, wantFees := "3.00000000", "0.00000000", 1, 1
			if mode == "disconnect" {
				wantBalance, wantHeld, wantFees = "5.00000000", "3.00000000", 0
			}
			if mode == "rollback" {
				wantBalance, wantHeld, wantCompletions, wantFees = "5.00000000", "3.00000000", 0, 0
			}
			if balance != wantBalance || held != wantHeld || completions != wantCompletions || fees != wantFees {
				t.Fatalf("original money: balance=%s hold=%s completions=%d fees=%d", balance, held, completions, fees)
			}
		})
	}
}
