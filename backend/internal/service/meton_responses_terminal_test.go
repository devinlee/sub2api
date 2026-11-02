//go:build unit

package service

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

/** 已交出部分输出不等于有完成证据；干净 EOF 和只有一半终态都不能补造完成。 */
func TestMetonResponsesChatFallbackTerminal(t *testing.T) {
	gin.SetMode(gin.TestMode)
	partial := "data: {\"id\":\"chatcmpl_meton\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
	finish := "data: {\"id\":\"chatcmpl_meton\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
	usage := "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}\n\n"
	done := "data: [DONE]\n\n"
	for _, item := range []struct {
		name string
		body string
		complete bool
	}{
		{"empty_eof", "", false},
		{"partial_clean_eof", partial, false},
		{"finish_without_done", partial + finish, false},
		{"done_without_finish", partial + done, false},
		{"only_done", done, false},
		{"usage_without_terminal", partial + usage, false},
		{"confirmed_completion", partial + finish + usage + done, true},
	} {
		t.Run(item.name, func(t *testing.T) {
			request := []byte(`{"model":"synthetic-text","input":"terminal fixture","stream":true}`)
			recorder := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(recorder)
			c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(request))
			upstream := &httpUpstreamRecorder{resp: &http.Response{
				StatusCode: http.StatusOK,
				Header: http.Header{"Content-Type": []string{"text/event-stream"}},
				Body: io.NopCloser(strings.NewReader(item.body)),
			}}
			svc := &OpenAIGatewayService{cfg: rawChatCompletionsTestConfig(), httpUpstream: upstream}
			result, err := svc.forwardResponsesViaRawChatCompletions(context.Background(), c, forceChatResponsesFallbackAccount(), request, time.Now())
			require.NotNil(t, result)
			if item.complete {
				require.NoError(t, err)
				require.Equal(t, 3, result.Usage.InputTokens)
				require.Equal(t, 2, result.Usage.OutputTokens)
				require.Contains(t, recorder.Body.String(), "event: response.completed")
				require.Contains(t, recorder.Body.String(), "data: [DONE]")
			} else {
				require.ErrorIs(t, err, ErrOpenAIUpstreamStreamTruncated)
				require.NotContains(t, recorder.Body.String(), "event: response.completed")
				require.NotContains(t, recorder.Body.String(), "response.output_item.done")
				require.NotContains(t, recorder.Body.String(), "data: [DONE]")
			}
		})
	}
}
