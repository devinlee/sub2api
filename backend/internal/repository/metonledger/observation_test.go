//go:build meton_managed && dispatch_integration

package metonledger

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch/dispatchtest"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
)

/** 原三条 SQL 适配分别只查询一次；计数不得改写成功、未授予和未知，也不得新增余额或派发操作。 */
func TestRejectionObservationLedgerAdapterOutcomes(t *testing.T) {
	for k, v := range map[string]string{"FUNDS_MODE": "s2-source-v1", "ENVIRONMENT": "s2-isolated", "SOURCE": "s2-managed", "EPOCH": "1"} {
		t.Setenv("METON_MANAGED_"+k, v)
	}
	body, key := []byte(`{"model":"meton-s2-text-fixture","input":"synthetic","max_output_tokens":128}`), []byte("fixture-secret")
	c := dispatchtest.Context(body, key)
	v := dispatchtest.New(t).Verify(t, c, body, key)
	profile, err := metonexecution.NewProfile(metonexecution.Spec{Version: "observation-v1", Protocol: c.Protocol, Model: c.Model, WireProtocol: c.Protocol, WireModel: c.Model, Target: "https://fixture.invalid/v1/responses", MaxBodyBytes: 256 * 1024, InputWindow: 1024, OutputWindow: 128})
	if err != nil {
		t.Fatal(err)
	}
	r, _ := http.NewRequest("POST", "https://fixture.invalid/v1/responses", bytes.NewReader(body))
	quote, err := profile.Quote(v, r, body)
	if err != nil {
		t.Fatal(err)
	}
	hold := &Hold{Origin: metonfee.Origin{Environment: c.Environment, Source: c.Source, User: c.User, Account: c.Account, Caller: c.Caller, OperationID: c.OperationID, SourceMarker: "synthetic-origin", SourceRequestID: "synthetic-request"}, AcceptedEpoch: c.Epoch,
		Estimate: Estimate{Protocol: c.Protocol, Model: c.Model, Digest: c.InputDigest, DigestVersion: c.DigestVersion, InputBound: 1024, OutputBound: 128}}
	session := SessionKey{ID: 1, Fingerprint: c.KeyDigest}
	call := Call{User: c.User, Account: c.Account, Caller: c.Caller, OperationID: c.OperationID, SourceMarker: hold.Origin.SourceMarker}
	unknown := errors.New("synthetic database response unknown")
	for _, route := range []string{"dispatch", "transport", "execution"} {
		for _, outcome := range []string{"first", "not-granted", "unknown"} {
			t.Run(route+"/"+outcome, func(t *testing.T) {
				db, mock, err := sqlmock.New()
				if err != nil {
					t.Fatal(err)
				}
				defer db.Close()
				ledger, err := NewTextLedger(db)
				if err != nil {
					t.Fatal(err)
				}
				observer, err := metonobserve.Install(metonobserve.Scope{Environment: c.Environment, Source: c.Source, Epoch: c.Epoch}, "ledger")
				if err != nil {
					t.Fatal(err)
				}
				defer observer.Close()
				name := map[string]string{"dispatch": "claim_text_dispatch", "transport": "claim_transport_text", "execution": "claim_execution_text"}[route]
				expect := mock.ExpectQuery("^SELECT meton_ledger\\." + name + "\\(")
				if outcome == "unknown" {
					expect.WillReturnError(unknown)
				} else {
					expect.WillReturnRows(sqlmock.NewRows([]string{"first"}).AddRow(outcome == "first"))
				}
				var first bool
				switch route {
				case "dispatch":
					first, err = ledger.ClaimDispatch(context.Background(), call, hold.Origin.SourceRequestID, session)
				case "transport":
					first, err = ledger.ClaimTransport(context.Background(), v, session, hold)
				default:
					first, err = ledger.ClaimExecution(context.Background(), v, session, hold, quote)
				}
				if first != (outcome == "first") || (outcome == "unknown" && !errors.Is(err, unknown)) || (outcome != "unknown" && err != nil) {
					t.Fatal("original outcome changed", first, err)
				}
				s, _ := observer.Snapshot()
				wantDenied, wantUnknown := uint64(0), uint64(0)
				if outcome == "not-granted" {
					wantDenied = 1
				}
				if outcome == "unknown" {
					wantUnknown = 1
				}
				if s.Counts[metonobserve.SendNotGranted].Value != wantDenied || s.Counts[metonobserve.SendQueryFailed].Value != wantUnknown || s.Counts[metonobserve.RepeatAttempt].Value != 0 || s.Counts[metonobserve.RegistrationConflict].Value != 0 {
					t.Fatal("wrong SQL outcome category", s)
				}
				if err = mock.ExpectationsWereMet(); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
