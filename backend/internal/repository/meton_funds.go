package repository

import (
	"context"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

// ManagedFunds 在来源数据库的一条只读语句中使用原创建号；不接受自报用户号或当前余额。
func (r *userRepository) ManagedFunds(ctx context.Context, s service.MetonManagedSource, op uuid.UUID) (*service.MetonFundsReceipt, error) {
	if r.sql == nil || op == uuid.Nil {
		return nil, service.ErrMetonClosed
	}
	x := service.MetonFundsReceipt{Version: 1, Origin: service.MetonManagedClaim{Version: 1, Environment: s.Environment, Source: s.Source, Epoch: s.Epoch, Operation: op}}
	rows, err := r.sql.QueryContext(ctx, "SELECT meton_user,account,dispatch,remote_user,source_marker,birth_marker,state,observed_at FROM public.meton_s1_funds_state($1,$2,$3,$4)",
		s.Environment, s.Source, s.Epoch, op)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	if err = rows.Scan(&x.Origin.User, &x.Origin.Account, &x.Origin.Dispatch, &x.RemoteUser, &x.SourceMarker, &x.BirthMarker, &x.State, &x.CheckedAt); err != nil {
		return nil, err
	}
	if rows.Next() || rows.Err() != nil {
		return nil, service.ErrMetonClosed
	}
	x.ValidUntil = x.CheckedAt.Add(5 * time.Second)
	if !s.ValidFunds(op, &x, time.Now()) {
		return nil, service.ErrMetonClosed
	}
	return &x, nil
}
