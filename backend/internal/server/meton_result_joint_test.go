//go:build meton_managed && dispatch_integration && unit

package server

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

/** 只执行新终局组合；环境、账号、发送和清理沿已经验证的专用工厂。 */
func TestMetonManagedResultJoint(t *testing.T) {
	t.Setenv("METON_RESULT_JOINT", "1")
	TestMetonManagedGatewayJoint(t)
}

/** 新入口必须真正经过托管白名单，不能因为只测处理器而漏掉生产入口的拒绝。 */
func TestMetonResultIngress(t *testing.T) {
	r := gin.New()
	r.Use(metonManagedIngress(metonIngressOptions{models: true}))
	path := "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request/result"
	called := 0
	r.Any(path, func(c *gin.Context) { called++; c.Status(204) })
	for _, method := range []string{"GET", "POST", "PUT", "PATCH", "DELETE"} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(method, "/api/v1/admin/meton/managed-accounts/a/model-calls/meton.chat.v1/b/result", nil))
		want := 403
		if method == "GET" {
			want = 204
		}
		if w.Code != want {
			t.Fatalf("result ingress method=%s status=%d", method, w.Code)
		}
	}
	if called != 1 {
		t.Fatal("result ingress granted write methods")
	}
}

/** 控制身份仅是测试密钥认证替身；查询、归属及数据库均走正式实现和受限角色。 */
func (f *jointFixture) resultReads(router *gin.Engine) {
	f.t.Setenv("METON_MANAGED_MODEL_READ_KEY_ID", strings.Repeat("9", 24))
	makeHandler := func(role string) *admin.UserHandler {
		s := service.NewAdminService(nil, repository.NewUserRepository(nil, jointDB(f.t, role)), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
		return admin.NewUserHandler(s, nil, nil, nil, nil, nil, nil)
	}
	auth := func(id, permission string) gin.HandlerFunc {
		key := "adm_sc_" + id + "_" + strings.Repeat(id[:1], 64)
		return func(c *gin.Context) {
			if c.GetHeader("Authorization") != "" || subtle.ConstantTimeCompare([]byte(c.GetHeader("x-api-key")), []byte(key)) != 1 {
				c.AbortWithStatus(403)
				return
			}
			p := &adminaccess.Principal{KeyID: id, Policy: adminaccess.Policy{GlobalPermissions: []string{permission}}}
			c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), p))
			c.Header("Cache-Control", "no-store")
			c.Next()
		}
	}
	base := "/api/v1/admin/meton/managed-accounts/:operation"
	router.GET(base, auth(strings.Repeat("2", 24), "meton.managed.read"), makeHandler("s2_entry_auth").MetonManaged)
	read := makeHandler("s2_model_read")
	group := router.Group(base+"/model-calls/:caller/:request", auth(strings.Repeat("9", 24), "meton.models.inspect"))
	group.GET("", read.MetonModelRead)
	group.GET("/result", read.MetonModelResult)
	group.GET("/fees/:event", read.MetonModelRead)
}

/** 使用真实格式的可控上游；仅改变终局事实，原模型路由和资金算法不被测试替换。 */
func (f *jointFixture) resultUpstream(w http.ResponseWriter, r *http.Request, mode string, streaming bool) {
	kind := strings.SplitN(mode, ":", 2)[0]
	w.Header().Set("Content-Type", "application/json")
	input, output := 1, 1
	if kind == "known_zero" {
		input, output = 0, 0
	}
	if r.URL.Path == "/v1/chat/completions" {
		if !streaming {
			f.t.Error("chat joint sample must stream")
			w.WriteHeader(400)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		text := "data: {\"id\":\"chat-result\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"synthetic-text\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"你好🙂\"},\"finish_reason\":null}]}\n\n" +
			"data: {\"id\":\"chat-result\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"synthetic-text\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-result\",\"type\":\"function\",\"function\":{\"name\":\"city\",\"arguments\":\"{\\\"city\\\":\\\"苏州\\\"}\"}}]},\"finish_reason\":null}]}\n\n" +
			"data: {\"id\":\"chat-result\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"synthetic-text\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":0}}}\n\ndata: [DONE]\n\n"
		_, _ = io.WriteString(w, text)
		return
	}
	if r.URL.Path != "/v1/responses" {
		f.t.Error("unexpected result joint route")
		w.WriteHeader(400)
		return
	}
	status := "completed"
	if kind == "source_failed" {
		status = "failed"
	}
	response := map[string]any{"id": "resp-result", "object": "response", "status": status, "model": "synthetic-text", "output": []any{
		map[string]any{"id": "msg-result", "type": "message", "status": "completed", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "你好🙂", "annotations": []any{}}}}},
		"usage": map[string]any{"input_tokens": input, "output_tokens": output, "total_tokens": input + output, "input_tokens_details": map[string]any{"cached_tokens": 0}}}
	if kind == "completed_unpriced" {
		delete(response, "usage")
	}
	if !streaming {
		_ = json.NewEncoder(w).Encode(response)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	_, _ = io.WriteString(w, "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg-result\",\"output_index\":0,\"content_index\":0,\"delta\":\"你好🙂\"}\n\n")
	if kind == "responses_truncated" {
		return
	}
	raw, _ := json.Marshal(response)
	_, _ = fmt.Fprintf(w, "event: response.%s\ndata: {\"type\":\"response.%s\",\"response\":%s}\n\n", status, status, raw)
}
