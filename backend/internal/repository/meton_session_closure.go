package repository

import (
	"context"
	"encoding/json"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

// 所有读取返回主库上的原关闭证明。针对单个绑定的读取永远不会返回模型 Key 原文。
func (r *userRepository) ManagedSessionClosure(ctx context.Context, s service.MetonKeySource, op uuid.UUID, req *service.MetonSessionCloseRequest, target *uuid.UUID) (*service.MetonClosedSession, error) {
	if r.sql == nil || op == uuid.Nil {
		return nil, service.ErrMetonClosed
	}
	if req != nil {
		claim, err := json.Marshal(req.Claim)
		if err != nil {
			return nil, err
		}
		if _, err = r.sql.ExecContext(ctx, "SELECT public.meton_close_original_session($1,$2,$3,$4::jsonb,$5)", s.Environment, s.Source, s.Epoch, string(claim), req.PermitUntil); err != nil {
			return nil, err
		}
	}
	rows, err := r.sql.QueryContext(ctx, `SELECT c.claim::text,c.closure_marker,c.closed_at,
		CASE WHEN $5::uuid IS NULL THEN 'summary' WHEN x.binding IS NULL THEN 'never_issued'
		  WHEN x.source_marker=c.source_marker AND x.session_id=c.session_id AND r.operation=x.operation AND k.status='inactive'
		    AND k.user_id=m.remote_user AND k.created_at=x.created_at AND k.expires_at=x.expires_at
		    AND encode(sha256(convert_to(k.key,'UTF8')),'hex')=x.material_sha256 THEN 'retired' ELSE 'conflict' END,
		x.key_marker,x.remote_key,x.claim::text FROM public.meton_managed_session_closures c
		JOIN public.meton_managed_creations m ON m.source_marker=c.source_marker
		JOIN public.meton_managed_fence f ON f.singleton AND f.enabled AND f.environment=m.environment AND f.source=m.source AND f.epoch=m.epoch
		LEFT JOIN public.meton_managed_keys x ON x.binding=$5::uuid
		LEFT JOIN public.meton_managed_key_retirements r ON r.operation=x.operation AND r.remote_key=x.remote_key AND r.key_marker=x.key_marker
		LEFT JOIN public.api_keys k ON k.id=x.remote_key
		WHERE NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off' AND f.environment=$1 AND f.source=$2 AND f.epoch=$3 AND c.operation=$4`,
		s.Environment, s.Source, s.Epoch, op, target)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	v := &service.MetonClosedSession{Version: 1, State: "closed"}
	var claim []byte
	var state string
	var marker *uuid.UUID
	var remote *int64
	var original []byte
	if err := rows.Scan(&claim, &v.ClosureMarker, &v.ClosedAt, &state, &marker, &remote, &original); err != nil {
		return nil, err
	}
	if rows.Next() || rows.Err() != nil || json.Unmarshal(claim, &v.Claim) != nil {
		return nil, service.ErrMetonClosed
	}
	if target != nil {
		v.Target = &service.MetonClosedTarget{Binding: *target, State: state, KeyMarker: marker, RemoteKey: remote}
		if len(original) > 0 {
			var k service.MetonKeyClaim
			if json.Unmarshal(original, &k) != nil {
				return nil, service.ErrMetonClosed
			}
			v.Target.KeyClaim = &k
		}
	}
	if !s.ValidClosureReply(op, req, target, v) {
		return nil, service.ErrMetonClosed
	}
	return v, nil
}
