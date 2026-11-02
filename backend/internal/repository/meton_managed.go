package repository

import (
	"context"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

// ManagedAccount 不在 SQL 层重试写；创建事务的结果丢失只允许调用方读回原记录。
func (r *userRepository) ManagedAccount(ctx context.Context, s service.MetonManagedSource, op uuid.UUID, c *service.MetonManagedClaim) (*service.MetonManagedReceipt, error) {
	if r.sql == nil || op == uuid.Nil || c != nil && (!s.ValidClaim(c) || c.Operation != op) {
		return nil, service.ErrMetonClosed
	}
	if c != nil {
		if _, err := r.sql.ExecContext(ctx, "SELECT public.meton_claim_managed_account($1,$2,$3,$4,$5,$6,$7)", s.Environment, s.Source, s.Epoch, c.User, c.Account, op, c.Dispatch); err != nil {
			return nil, err
		}
	}
	rows, err := r.sql.QueryContext(ctx, `SELECT m.meton_user,m.account,m.dispatch,m.remote_user,m.source_marker
        FROM public.meton_managed_creations m JOIN public.meton_managed_fence f ON f.singleton AND f.enabled AND
        f.environment=m.environment AND f.source=m.source AND f.epoch=m.epoch
        JOIN public.users u ON u.id=m.remote_user AND u.role='user' AND u.status='active' AND u.deleted_at IS NULL
        AND u.email='meton-'||m.account::text||'@managed.invalid' AND u.restrict_public_groups
        WHERE m.environment=$1 AND m.source=$2 AND m.epoch=$3 AND m.operation=$4`, s.Environment, s.Source, s.Epoch, op)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	result := &service.MetonManagedReceipt{MetonManagedClaim: service.MetonManagedClaim{Version: 1, Environment: s.Environment, Source: s.Source, Epoch: s.Epoch, Operation: op}, State: "managed", RestrictPublicGroups: true}
	if err = rows.Scan(&result.User, &result.Account, &result.Dispatch, &result.RemoteUser, &result.SourceMarker); err != nil {
		return nil, err
	}
	if !s.ValidClaim(&result.MetonManagedClaim) || result.SourceMarker == uuid.Nil || result.RemoteUser < 1 || rows.Next() {
		return nil, service.ErrMetonClosed
	}
	return result, rows.Err()
}
