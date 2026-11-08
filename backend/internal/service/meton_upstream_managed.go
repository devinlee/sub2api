//go:build meton_managed

package service

import (
	"context"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
)

/** 原生路径在解析和出站前都核对原受理；不可计数的独立插件不能被当作一次网络调用。 */
func metonModelForwardAllowed(ctx context.Context, account *Account, plugins *PluginManager) error {
	if !metontransport.Current(ctx) || account == nil || account.ID < 1 || account.Platform != PlatformOpenAI ||
		!(account.IsOpenAIApiKey() || account.IsOpenAIOAuthLike()) || plugins != nil && plugins.ShouldRouteOpenAIOAuth(account) {
		return ErrMetonClosed
	}
	return nil
}

/** 已受理的原调用任何转发错误都不能变成换账户许可；原查询和费用状态另按持久记录核对。 */
func metonModelForwardError(ctx context.Context, err error) error {
	if err != nil && metontransport.Bound(ctx) {
		return ErrMetonClosed
	}
	return err
}

/** 本地资格拒绝或原调用的网络未知不处罚另一供应账户，不进入原生重试分类。 */
func metonOriginalTransport(ctx context.Context) bool { return metontransport.Bound(ctx) }

/** MetonTextAdmitted 只允许原生文本调度使用认证时固定的主体；不能通过换 APIKey 对象串号。 */
func MetonTextAdmitted(ctx context.Context, key *APIKey) bool {
	return key != nil && key.User != nil && key.Group != nil && key.GroupID != nil && *key.GroupID == key.Group.ID && key.UserID == key.User.ID &&
		key.Group.Platform == PlatformOpenAI && !key.Group.IsSubscriptionType() &&
		metontransport.Admitted(ctx, metontransport.Subject{User: key.UserID, Key: key.ID, Group: key.Group.ID})
}

func metonBillingPreflight(ctx context.Context, user *User, key *APIKey, group *Group, subscription *UserSubscription) error {
	if user == nil || key == nil || group == nil || subscription != nil || user.ID != key.UserID || key.GroupID == nil || group.ID != *key.GroupID || !MetonTextAdmitted(ctx, key) {
		return ErrMetonClosed
	}
	return nil
}
