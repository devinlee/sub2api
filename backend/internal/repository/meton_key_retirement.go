package repository

import (
	"context"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

// 当前鉴权始终再次到主库，掌握旧哈希或用户编号都不能跨过关停、换代或过期。
func (r *apiKeyRepository) CurrentManagedKey(ctx context.Context, s service.MetonKeySource, key, user int64, hash string) (bool, error) {
	if r.sql == nil {
		return false, service.ErrMetonClosed
	}
	rows, err := r.sql.QueryContext(ctx, "SELECT NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off' AND public.meton_current_key($1,$2,$3,$4,$5,$6)",
		s.Environment, s.Source, s.Epoch, key, user, hash)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	var value bool
	if !rows.Next() {
		return false, service.ErrMetonClosed
	}
	if err = rows.Scan(&value); err != nil {
		return false, err
	}
	if rows.Next() || rows.Err() != nil {
		return false, service.ErrMetonClosed
	}
	return value, nil
}
func (r *userRepository) ManagedRetirement(ctx context.Context, s service.MetonKeySource, op uuid.UUID, req *service.MetonRetireRequest) (*service.MetonRetiredKey, error) {
	if r.sql == nil || op == uuid.Nil {
		return nil, service.ErrMetonClosed
	}
	if req != nil {
		data, err := json.Marshal(req.Claim)
		if err != nil {
			return nil, err
		}
		_, err = r.sql.ExecContext(ctx, "SELECT public.meton_retire_key_for_rotation($1,$2,$3,$4::jsonb,$5,$6,$7)", s.Environment, s.Source, s.Epoch, string(data), req.KeyMarker, req.RemoteKey, req.PermitUntil)
		if err != nil {
			return nil, err
		}
	}
	rows, err := r.sql.QueryContext(ctx, `SELECT x.claim::text,r.key_marker,r.remote_key,r.retired_at FROM public.meton_managed_key_retirements r
        JOIN public.meton_managed_keys x ON x.operation=r.operation AND x.key_marker=r.key_marker AND x.remote_key=r.remote_key
        JOIN public.meton_managed_creations m ON m.source_marker=x.source_marker
        JOIN public.meton_managed_fence f ON f.singleton AND f.enabled AND m.environment=f.environment AND m.source=f.source AND m.epoch=f.epoch
        JOIN public.api_keys k ON k.id=r.remote_key AND k.user_id=m.remote_user AND k.status='inactive'
        WHERE NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off' AND f.environment=$1 AND f.source=$2 AND f.epoch=$3 AND r.operation=$4`,
		s.Environment, s.Source, s.Epoch, op)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	reply := &service.MetonRetiredKey{Version: 1, State: "retired"}
	var data string
	if err = rows.Scan(&data, &reply.KeyMarker, &reply.RemoteKey, &reply.RetiredAt); err != nil {
		return nil, err
	}
	if json.Unmarshal([]byte(data), &reply.Claim) != nil || !s.Valid(reply.Claim) || reply.Claim.Operation != op || rows.Next() || rows.Err() != nil {
		return nil, service.ErrMetonClosed
	}
	return reply, nil
}
