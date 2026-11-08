//go:build !meton_managed

package server

import "github.com/Wei-Shaw/sub2api/internal/service"

/** 普通构建不读取托管恢复配置或取得新权限。 */
func ProvideMetonResultControl(service.AccountRepository) (*MetonResultIngress, error) {
	return &MetonResultIngress{}, nil
}
