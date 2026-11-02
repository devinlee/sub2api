package repository

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
	"time"
)

// 一次事务创建且只有赢得原签发的这一次响应带秘密。查询和重复提交不会从 api_keys 读回明文。
func (r *userRepository) ManagedKey(ctx context.Context, s service.MetonKeySource, op uuid.UUID, issue *service.MetonKeyRequest) (*service.MetonKeyReply, error) {
	if r.sql == nil || op == uuid.Nil {
		return nil, service.ErrMetonClosed
	}
	secret := ""
	if issue != nil {
		if issue.Claim.Operation != op || !s.CanIssue(issue, time.Now()) {
			return nil, service.ErrMetonClosed
		}
		raw := make([]byte, 32)
		if _, err := rand.Read(raw); err != nil {
			return nil, err
		}
		secret = "sk-" + hex.EncodeToString(raw)
		clear(raw)
		claim, err := json.Marshal(issue.Claim)
		if err != nil {
			return nil, err
		}
		rows, err := r.sql.QueryContext(ctx, "SELECT public.meton_issue_managed_key($1,$2,$3,$4::jsonb,$5,$6)", s.Environment, s.Source, s.Epoch, string(claim), issue.PermitUntil, secret)
		if err != nil {
			return nil, err
		}
		created := false
		if !rows.Next() {
			rows.Close()
			return nil, service.ErrMetonClosed
		}
		err = rows.Scan(&created)
		// 函数有且只有一行，必须读到命令完成才认为提交结果可用。
		extra := rows.Next()
		endErr := rows.Err()
		rows.Close()
		if err != nil || extra || endErr != nil {
			return nil, service.ErrMetonClosed
		}
		if !created {
			secret = ""
		}
	}
	rows, err := r.sql.QueryContext(ctx, `SELECT x.claim::text,x.key_marker,x.remote_key,x.created_at,x.expires_at,x.material_sha256
        FROM public.meton_managed_keys x JOIN public.meton_managed_creations m ON m.source_marker=x.source_marker
        JOIN public.meton_managed_fence f ON f.singleton AND f.enabled AND f.environment=m.environment AND f.source=m.source AND f.epoch=m.epoch
        JOIN public.users u ON u.id=m.remote_user AND u.role='user' AND u.status='active' AND u.deleted_at IS NULL AND u.restrict_public_groups
        JOIN public.api_keys k ON k.id=x.remote_key AND k.user_id=m.remote_user AND k.deleted_at IS NULL AND k.status='active'
        AND k.created_at=x.created_at AND k.expires_at=x.expires_at AND k.group_id IS NULL
        AND encode(sha256(convert_to(k.key,'UTF8')),'hex')=x.material_sha256
        WHERE m.environment=$1 AND m.source=$2 AND m.epoch=$3 AND x.operation=$4`, s.Environment, s.Source, s.Epoch, op)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	reply := &service.MetonKeyReply{Version: 1, Purpose: "model", State: "issued"}
	var raw string
	if err = rows.Scan(&raw, &reply.KeyMarker, &reply.RemoteKey, &reply.CreatedAt, &reply.ExpiresAt, &reply.MaterialSha256); err != nil {
		return nil, err
	}
	if err = json.Unmarshal([]byte(raw), &reply.Claim); err != nil || !s.Valid(reply.Claim) || reply.Claim.Operation != op ||
		reply.KeyMarker == uuid.Nil || reply.RemoteKey <= 0 || !reply.ExpiresAt.After(reply.CreatedAt) || reply.ExpiresAt.Sub(reply.CreatedAt) > 24*time.Hour ||
		rows.Next() || rows.Err() != nil {
		return nil, service.ErrMetonClosed
	}
	if secret != "" {
		h := sha256.Sum256([]byte(secret))
		if hex.EncodeToString(h[:]) != reply.MaterialSha256 {
			return nil, service.ErrMetonClosed
		}
		reply.Secret = secret
	}
	return reply, nil
}
