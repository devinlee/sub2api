//go:build !meton_managed

package server

import "github.com/Wei-Shaw/sub2api/internal/service"

/** 普通构建没有托管运行池或原模型路由，不消费托管环境变量。 */
func ProvideMetonTextIngress(*service.APIKeyService, service.GroupRepository, *service.PaymentConfigService) (*MetonTextIngress, error) {
	return &MetonTextIngress{}, nil
}
