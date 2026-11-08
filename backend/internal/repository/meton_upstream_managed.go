//go:build meton_managed

package repository

import (
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
	"net/http"
)

/** 托管上游必须消费原受理；不套用原生 Grok 换站或其他会重试的 Transport。 */
func metonUpstreamClient(client *http.Client, request *http.Request, account int64) (*http.Client, error) {
	result, err := metontransport.ClientForProvider(client, request, account)
	if err != nil && request != nil && request.Body != nil {
		_ = request.Body.Close()
	}
	return result, err
}
