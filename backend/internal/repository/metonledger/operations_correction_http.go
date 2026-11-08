//go:build meton_managed

package metonledger

import (
	"context"
	"strconv"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
)

/** WithCorrectionAccess 只绑定当前请求的副本；连接池共享，其他并发请求无法沿用该证明。 */
func (l *TextLedger) WithCorrectionAccess(a metonmodel.CorrectionAccess) *TextLedger {
	scoped := *l
	scoped.correctionAccess = &a
	return &scoped
}

/** 两种入口使用相同的结果核验。HTTP 角色在数据库只获包含权限锁的函数。 */
func (l *TextLedger) correctionCommand(ctx context.Context, o metonfee.Origin, name string, extra []any, out any) error {
	if a := l.correctionAccess; a != nil {
		name = "http_" + name
		extra = append(extra, a.KeyID, a.CreatorID, a.Revision, a.Until.UnixMilli(), a.Witness)
	}
	// 前九个参数始终是 feeCommand 从可信来源和原请求构造的参数；函数名只来自本包固定调用点。
	params := make([]string, 9+len(extra))
	for i := range params {
		params[i] = "$" + strconv.Itoa(i+1)
	}
	return l.feeCommand(ctx, o, name+"("+strings.Join(params, ",")+")", extra, out)
}
