//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

type cashManualReviewConfiguration struct {
	DSNFile         string `json:"dsn_file"`
	MaterialKeyFile string `json:"material_key_file"`
	MaterialKeyRef  string `json:"material_key_ref"`
}

/** 审核连接、材料密钥和服务用途都必须显式配置；错误配置在监听前失败，不借用旧角色。 */
func openCashManualReview(base string, cfg *cashManualReviewConfiguration, route json.RawMessage, source service.MetonManagedSource) (*cashManualReviewStore, func(), error) {
	if cfg == nil {
		return nil, func() {}, nil
	}
	if _, ok := source.CashManualReviewKeyID(); !ok || cfg.DSNFile == "" || cfg.MaterialKeyFile == "" || cfg.MaterialKeyRef == "" || len(cfg.MaterialKeyRef) > 120 {
		return nil, func() {}, service.ErrMetonClosed
	}
	material, err := readFile(base, cfg.DSNFile, 32768)
	if err != nil {
		return nil, func() {}, err
	}
	cipher, err := loadCashRecoveryKey(base, cfg.MaterialKeyFile)
	if err != nil {
		return nil, func() {}, err
	}
	db, err := sql.Open("postgres", strings.TrimSpace(string(material)))
	if err != nil {
		return nil, func() {}, service.ErrMetonClosed
	}
	close := func() { _ = db.Close() }
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	var ready bool
	if err = db.QueryRowContext(ctx, "SELECT meton_inbox.cash_manual_review_ready($1)", string(route)).Scan(&ready); err != nil || !ready {
		close()
		return nil, func() {}, service.ErrMetonClosed
	}
	return &cashManualReviewStore{materials: &refundPayerReviewStore{archive: db, cipher: cipher, keyRef: cfg.MaterialKeyRef}, route: route}, close, nil
}

/** 人员上下文只能使用审核池；只读池与原重试池不能代替它。 */
func (s *cashArchiveStore) ReadCashManualReview(ctx context.Context, key string) (json.RawMessage, error) {
	if s.review == nil {
		return nil, service.ErrMetonClosed
	}
	return s.review.context(ctx, key)
}

/** 原操作只交一次，模式由固定服务路由选择。 */
func (s *cashArchiveStore) RecordCashManualReview(ctx context.Context, q service.CashManualReviewCommand, material []byte, resultOnly bool) (json.RawMessage, error) {
	if s.review == nil {
		return nil, service.ErrMetonClosed
	}
	return s.review.record(ctx, q, material, resultOnly)
}
