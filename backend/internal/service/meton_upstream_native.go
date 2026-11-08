//go:build !meton_managed

package service

import "context"

/** 普通构建沿用原生账户与插件策略。 */
func metonModelForwardAllowed(context.Context, *Account, *PluginManager) error { return nil }

func metonModelForwardError(_ context.Context, err error) error { return err }
func metonOriginalTransport(context.Context) bool               { return false }

func MetonTextAdmitted(context.Context, *APIKey) bool { return false }
func metonBillingPreflight(context.Context, *User, *APIKey, *Group, *UserSubscription) error {
	return ErrMetonClosed
}
