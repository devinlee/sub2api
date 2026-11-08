//go:build meton_managed && dispatch_integration && unit

package server

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"net/http"
	"strings"
	"testing"
)

/** 只增加真实桌面所需的来源接口，不重跑已通过的账本和恢复矩阵。 */
func TestMetonManagedDesktopJoint(t *testing.T) {
	t.Setenv("METON_DESKTOP_JOINT", "1")
	TestMetonManagedControlJoint(t)
}

/** 测试用途只允许两组固定身份，不从模型输入取得环境或来源。 */
func (f *jointFixture) sourceName() string {
	if f.desktopMode {
		return "s1-managed"
	}
	return "synthetic-model-access"
}
func (f *jointFixture) serviceName() string {
	if f.desktopMode {
		return "meton-s0"
	}
	return "model-call-grain-tests"
}

/** 管理身份认证仍是明确的测试替身；账号、Key、停用和查询使用原处理器与原数据库。 */
func (f *jointFixture) desktopRoutes(router *gin.Engine) {
	f.t.Setenv("METON_MANAGED_ROTATE_KEY_ID", strings.Repeat("5", 24))
	f.t.Setenv("METON_MANAGED_CLOSE_KEY_ID", strings.Repeat("6", 24))
	serviceInstance := service.NewAdminService(nil, repository.NewUserRepository(nil, f.admin), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
	handler := admin.NewUserHandler(serviceInstance, nil, nil, nil, nil, nil, nil)
	auth := func(id, permission string) gin.HandlerFunc {
		return func(c *gin.Context) {
			expected := "adm_sc_" + strings.Repeat(id, 24) + "_" + strings.Repeat(id, 64)
			if c.GetHeader("Authorization") != "" || subtle.ConstantTimeCompare([]byte(c.GetHeader("x-api-key")), []byte(expected)) != 1 {
				c.AbortWithStatus(403)
				return
			}
			principal := &adminaccess.Principal{KeyID: strings.Repeat(id, 24), Policy: adminaccess.Policy{GlobalPermissions: []string{permission}}}
			c.Request = c.Request.WithContext(adminaccess.WithPrincipal(c.Request.Context(), principal))
			c.Header("Cache-Control", "no-store")
			c.Next()
		}
	}
	base := "/api/v1/admin/meton"
	// 账号只读路由沿 resultReads，避免覆盖已经注册的受限查询路径。
	router.POST(base+"/managed-accounts", auth("1", "meton.managed.create"), handler.MetonManaged)
	router.POST(base+"/managed-keys", auth("3", "meton.keys.issue"), handler.MetonManagedKey)
	router.GET(base+"/managed-keys/:operation", auth("4", "meton.keys.inspect"), handler.MetonManagedKey)
	router.POST(base+"/managed-keys/:operation/retirement", auth("5", "meton.keys.rotate"), handler.MetonKeyRetirement)
	router.GET(base+"/managed-keys/:operation/retirement", auth("4", "meton.keys.inspect"), handler.MetonKeyRetirement)
	router.POST(base+"/session-closures/:operation", auth("6", "meton.sessions.close"), handler.MetonSessionClosure)
	router.GET(base+"/session-closures/:operation", auth("4", "meton.keys.inspect"), handler.MetonSessionClosure)
	router.GET(base+"/session-closures/:operation/keys/:binding", auth("4", "meton.keys.inspect"), handler.MetonSessionClosure)
}

/** 上游为零费用合成内容；工具必须由真实原生运行时执行，夹具不代做文件读取。 */
func (f *jointFixture) desktopUpstream(w http.ResponseWriter, r *http.Request, input json.RawMessage, messages []struct {
	Role    string
	Content json.RawMessage
}, tools json.RawMessage, stream bool) {
	if r.Header.Get(metondispatch.ContextHeader) != "" || r.Header.Get(metondispatch.ProofHeader) != "" {
		f.t.Error("desktop leaked service proof")
		w.WriteHeader(500)
		return
	}
	text := jointText(input)
	toolDone := false
	for _, m := range messages {
		if m.Role == "user" {
			text = jointText(m.Content)
		}
		if m.Role == "tool" && strings.Contains(string(m.Content), "METON_DESKTOP_TOOL_PROOF") {
			toolDone = true
		}
	}
	kind := "desktop-sdk"
	content := "METON_DESKTOP_SDK_DONE"
	finish := "stop"
	delta := map[string]any{"role": "assistant", "content": content}
	if strings.Contains(text, "METON_DESKTOP_TOOL") {
		kind = "desktop-chat"
		content = "METON_DESKTOP_CHAT_DONE"
		delta["content"] = content
		if !toolDone {
			if !strings.Contains(string(tools), `"read"`) {
				f.t.Error("desktop read tool absent")
				w.WriteHeader(400)
				return
			}
			finish = "tool_calls"
			// 文件由本次桌面在自己的私有工作目录创建，真实工具负责读取；夹具只声明工具参数。
			var probe string
			if json.Unmarshal([]byte(strings.TrimPrefix(text, "METON_DESKTOP_TOOL ")), &probe) != nil || !strings.HasSuffix(probe, `\probe.txt`) {
				f.t.Error("desktop probe path absent")
				w.WriteHeader(400)
				return
			}
			arguments, _ := json.Marshal(map[string]string{"path": probe})
			delta = map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"index": 0, "id": "call_desktop_read", "type": "function", "function": map[string]any{"name": "read", "arguments": string(arguments)}}}}
		}
	}
	f.mu.Lock()
	f.calls[kind]++
	f.mu.Unlock()
	if r.URL.Path != "/v1/chat/completions" || !stream {
		f.t.Error("unexpected desktop protocol")
		w.WriteHeader(400)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	frame := func(d any, reason any, usage bool) {
		v := map[string]any{"id": "chat-desktop", "object": "chat.completion.chunk", "created": 1, "model": "synthetic-text", "choices": []any{map[string]any{"index": 0, "delta": d, "finish_reason": reason}}}
		if usage {
			// 费用观察器不能把缺失缓存量猜成零；合成上游明确报告本次没有缓存命中。
			v["usage"] = map[string]any{"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2, "prompt_tokens_details": map[string]int{"cached_tokens": 0}}
		}
		raw, _ := json.Marshal(v)
		_, _ = fmt.Fprintf(w, "data: %s\n\n", raw)
	}
	frame(delta, nil, false)
	frame(map[string]any{}, finish, true)
	_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
}
