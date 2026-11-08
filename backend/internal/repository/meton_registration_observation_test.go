//go:build unit && meton_managed

package repository

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
	"github.com/lib/pq"
)

/** 只计原兑换冲突，同参成功重放不计拒绝；查原和其他数据库错误不能被推断成重复赠送。 */
func TestRejectionObservationRegistrationOutcomes(t *testing.T) {
	source := service.MetonManagedSource{Environment: "s2-isolated", Source: "s2-managed", Epoch: 1}
	creation, eligibility := uuid.New(), uuid.New()
	grant := &service.MetonRegistrationGrant{MetonManagedClaim: service.MetonManagedClaim{Version: 1, Environment: source.Environment, Source: source.Source, Epoch: 1, User: uuid.New(), Account: uuid.New(), Operation: creation, Dispatch: uuid.New()}, RemoteUser: 1, SourceMarker: uuid.New(), Eligibility: eligibility, Rule: "initial-v1", Unit: "credit", Amount: "1.00000000"}
	for _, name := range []string{"replay", "conflict", "unknown", "read-conflict"} {
		t.Run(name, func(t *testing.T) {
			db, mock, err := sqlmock.New()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			observer, err := metonobserve.Install(metonobserve.Scope{Environment: source.Environment, Source: source.Source, Epoch: source.Epoch}, "registration")
			if err != nil {
				t.Fatal(err)
			}
			defer observer.Close()
			repo := &userRepository{sql: db}
			request := grant
			query := "redeem_registration"
			if name == "read-conflict" {
				request = nil
				query = "find_registration"
			}
			iterations := 1
			if name == "replay" {
				iterations = 2
			}
			event := uuid.New()
			for i := 0; i < iterations; i++ {
				expected := mock.ExpectQuery("FROM meton_ledger\\." + query + "\\(")
				var dbError error
				if name == "replay" {
					expected.WillReturnRows(sqlmock.NewRows([]string{"meton_user", "account", "creation", "dispatch", "remote_user", "source_marker", "eligibility", "business_code", "event_id", "native_code_id", "rule", "unit", "amount"}).AddRow(grant.User, grant.Account, creation, grant.Dispatch, grant.RemoteUser, grant.SourceMarker, eligibility, strings.ReplaceAll(eligibility.String(), "-", ""), event, 10, grant.Rule, grant.Unit, grant.Amount))
				} else {
					code := "23505"
					if name == "unknown" {
						code = "08006"
					}
					dbError = &pq.Error{Code: pq.ErrorCode(code), Message: "synthetic private diagnostic"}
					expected.WillReturnError(dbError)
				}
				result, err := repo.RegistrationGrant(context.Background(), source, creation, eligibility, request)
				switch name {
				case "replay":
					if err != nil || result == nil || result.Event != event || result.MetonRegistrationGrant != *grant {
						t.Fatal("replay changed", result, err)
					}
				case "conflict":
					if !errors.Is(err, service.ErrMetonGrantConflict) {
						t.Fatal("conflict changed", err)
					}
				default:
					if !errors.Is(err, dbError) {
						t.Fatal("query outcome changed", err)
					}
				}
			}
			s, _ := observer.Snapshot()
			want := uint64(0)
			if name == "conflict" {
				want = 1
			}
			for _, count := range s.Counts {
				expected := uint64(0)
				if count.Kind == "registration_conflict" {
					expected = want
				}
				if count.Value != expected {
					t.Fatal("replay or unknown counted as conflict", s)
				}
			}
			if err = mock.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
