//go:build meton_managed

package metonentry

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type cashArchiveLink struct {
	Facts struct {
		Format      int                              `json:"format"`
		Purpose     string                           `json:"purpose"`
		Scope       service.CashArchiveOriginalScope `json:"scope"`
		ScopeKey    string                           `json:"scopeKey"`
		OriginalKey string                           `json:"originalKey"`
		Item        json.RawMessage                  `json:"item"`
		Link        json.RawMessage                  `json:"link"`
		ValidUntil  time.Time                        `json:"validUntil"`
	} `json:"facts"`
	Mac string `json:"mac"`
}

/** 每个实际数据库单独提交只读事务；不使用跨库事务、写角色或归档的来源别名。 */
func archiveOriginalQuery(ctx context.Context, db *sql.DB, statement string, args ...any) (json.RawMessage, error) {
	if db == nil {
		return nil, service.ErrMetonClosed
	}
	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var value []byte
	if err = tx.QueryRowContext(ctx, statement, args...).Scan(&value); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return value, nil
}

/** 来源观察前后读取同一原归档。证明只在本次内存交接，变化、撤权及失联一律不交付旧结果。 */
func (s *cashArchiveStore) ReadCashArchiveOriginal(ctx context.Context, q service.CashArchiveRequest) (json.RawMessage, error) {
	if s.source == nil || q.OriginalKey == nil || q.After != nil || q.Size != 1 {
		return nil, service.ErrMetonClosed
	}
	var scope service.CashArchiveOriginalScope
	if metonexecution.DecodeStrict(s.route, &scope) != nil {
		return nil, service.ErrMetonClosed
	}
	read := func() (json.RawMessage, cashArchiveLink, error) {
		raw, err := archiveOriginalQuery(ctx, s.db, "SELECT meton_inbox.read_cash_archive_link($1,$2)", string(s.route), *q.OriginalKey)
		var link cashArchiveLink
		if err != nil {
			return nil, link, err
		}
		if len(raw) > 33792 || metonexecution.DecodeStrict(raw, &link) != nil || link.Facts.Format != 1 ||
			link.Facts.Purpose != "cash.archive.original.read.v1" || link.Facts.Scope != scope || link.Facts.OriginalKey != *q.OriginalKey ||
			link.Facts.ScopeKey != q.ScopeKey || len(link.Mac) != 64 || len(link.Facts.Item) == 0 || len(link.Facts.Link) == 0 ||
			!link.Facts.ValidUntil.After(time.Now()) || link.Facts.ValidUntil.After(time.Now().Add(30*time.Second)) {
			return nil, link, service.ErrMetonClosed
		}
		return raw, link, nil
	}
	proof, first, err := read()
	if err != nil {
		return nil, err
	}
	result, err := archiveOriginalQuery(ctx, s.source, "SELECT meton_ledger.read_cash_archive_original($1,$2)", string(s.route), string(proof))
	if err != nil {
		return nil, err
	}
	_, last, err := read()
	if err != nil {
		return nil, err
	}
	if !first.Facts.ValidUntil.After(time.Now()) || first.Facts.Scope != last.Facts.Scope || first.Facts.ScopeKey != last.Facts.ScopeKey ||
		first.Facts.OriginalKey != last.Facts.OriginalKey || !bytes.Equal(first.Facts.Item, last.Facts.Item) || !bytes.Equal(first.Facts.Link, last.Facts.Link) || ctx.Err() != nil {
		return nil, service.ErrMetonClosed
	}
	// 私有查询结果也须仍属于固定部署路由；不能把另一个来源的成功 JSON 当成当前响应。
	var observed struct {
		Scope service.CashArchiveOriginalScope `json:"scope"`
	}
	if json.Unmarshal(result, &observed) != nil || observed.Scope != scope {
		return nil, service.ErrMetonClosed
	}
	return result, nil
}
