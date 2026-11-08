//go:build !meton_managed

package repository

import "net/http"

/** 普通构建保留原有连接池与兼容回退，不引入 Meton 发送状态。 */
func metonUpstreamClient(client *http.Client, _ *http.Request, _ int64) (*http.Client, error) {
	return httpClientWithGrokAccessDeniedFallback(client), nil
}
