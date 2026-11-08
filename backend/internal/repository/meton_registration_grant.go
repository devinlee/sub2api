package repository

import (
	"context"
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
	"github.com/lib/pq"
)

// RegistrationGrant 一条 SQL 调用即一个事务。写入回应丢失后，读取只查原操作，不重试写入。
func (r *userRepository) RegistrationGrant(ctx context.Context, s service.MetonManagedSource, creation, grant uuid.UUID, q *service.MetonRegistrationGrant) (*service.MetonGrantReceipt, error) {
	if r.sql == nil {
		return nil, service.ErrMetonClosed
	}
	const columns = "SELECT meton_user,account,creation,dispatch,remote_user,source_marker,eligibility,business_code,event_id,native_code_id,rule,unit,amount FROM "
	query := columns + "meton_ledger.find_registration($1,$2,$3,$4,$5)"
	params := []any{s.Environment, s.Source, s.Epoch, creation}
	if q == nil {
		params = append(params, grant)
	} else {
		if !s.ValidRegistrationGrant(q, creation, grant) {
			return nil, service.ErrMetonClosed
		}
		query = columns + "meton_ledger.redeem_registration($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)"
		params = append(params, q.User, q.Account, q.Dispatch, q.RemoteUser, q.SourceMarker, grant, q.Rule, q.Unit, q.Amount)
	}
	rows, err := r.sql.QueryContext(ctx, query, params...)
	if err != nil {
		var original *pq.Error
		if q != nil && errors.As(err, &original) && original.Code == "23505" {
			metonobserve.Record(metonobserve.Scope{Environment: s.Environment, Source: s.Source, Epoch: s.Epoch}, metonobserve.RegistrationConflict)
			return nil, service.ErrMetonGrantConflict
		}
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	var result service.MetonGrantReceipt
	result.Version, result.Environment, result.Source, result.Epoch, result.State = 1, s.Environment, s.Source, s.Epoch, "redeemed"
	if err = rows.Scan(&result.User, &result.Account, &result.Operation, &result.Dispatch, &result.RemoteUser, &result.SourceMarker, &result.Eligibility,
		&result.BusinessCode, &result.Event, &result.NativeCodeID, &result.Rule, &result.Unit, &result.Amount); err != nil {
		return nil, err
	}
	if rows.Next() || rows.Err() != nil {
		return nil, service.ErrMetonClosed
	}
	return &result, nil
}
