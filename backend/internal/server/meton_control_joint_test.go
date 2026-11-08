//go:build meton_managed && dispatch_integration && unit

package server

import (
	"crypto/subtle"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/handler/admin"
	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type jointControlState struct {
	mu                     sync.Mutex
	modes                  map[string]string
	writes, reads, applied map[string]int
	gates                  map[string]chan struct{}
}

/** 沿既有隔离工厂组合新控制接口，不重跑原终局和账本测试。 */
func TestMetonManagedControlJoint(t *testing.T) {
	t.Setenv("METON_RESULT_JOINT", "1")
	t.Setenv("METON_CONTROL_JOINT", "1")
	TestMetonManagedGatewayJoint(t)
}

/** 夹具故障只干预实际处理器回应，不替换来源取消事务或余额。 */
func newJointControlState() *jointControlState {
	return &jointControlState{modes: map[string]string{}, writes: map[string]int{}, reads: map[string]int{}, applied: map[string]int{}, gates: map[string]chan struct{}{}}
}

/** 两个新连接仅有原控制包装函数权限；来源继续使用原预占、发送、结算和终局读取四池。 */
func (f *jointFixture) executionRoutes(router *gin.Engine, entry *metonentry.Admission) error {
	f.t.Setenv("METON_MANAGED_MODEL_CANCEL_KEY_ID", strings.Repeat("a", 24))
	control, err := metonentry.NewOriginalExecutionControl(jointDB(f.t, "s2_original_read"), jointDB(f.t, "s2_original_cancel"))
	if err != nil {
		return err
	}
	entry.Control = control
	h := admin.NewUserHandler(nil, nil, nil, nil, nil, nil, nil)
	h.SetMetonModelControl(entry.Control)
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
	base := "/api/v1/admin/meton/managed-accounts/:operation/model-calls/:caller/:request"
	router.GET(base+"/execution", auth(strings.Repeat("9", 24), "meton.models.inspect"), h.MetonModelExecution)
	router.POST(base+"/cancel", auth(strings.Repeat("a", 24), "meton.models.cancel"), h.MetonModelCancel)
	return nil
}

/** 每次真实请求只处理一次；丢回应和暂停回应均发生在真实数据库操作之后。 */
func (f *jointFixture) executionResponse(w http.ResponseWriter, r *http.Request, router *gin.Engine) bool {
	p := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(p) != 10 || p[6] != "model-calls" || p[9] != "cancel" && p[9] != "execution" {
		return false
	}
	op := p[8]
	s := f.controlState
	s.mu.Lock()
	if r.Method == "POST" {
		s.writes[op]++
	} else {
		s.reads[op]++
	}
	mode, gate := s.modes[op], s.gates[op]
	s.mu.Unlock()
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, r)
	if r.Method == "POST" && recorder.Code == 200 {
		s.mu.Lock()
		s.applied[op]++
		s.mu.Unlock()
		if mode == "drop_reply" {
			if hijacker, ok := w.(http.Hijacker); ok {
				conn, _, err := hijacker.Hijack()
				if err == nil {
					_ = conn.Close()
					return true
				}
			}
			w.WriteHeader(503)
			return true
		}
		if mode == "pause_reply" && gate != nil {
			select {
			case <-gate:
			case <-r.Context().Done():
				return true
			}
		}
	}
	for key, values := range recorder.Header() {
		w.Header()[key] = values
	}
	w.WriteHeader(recorder.Code)
	_, _ = io.Copy(w, recorder.Body)
	return true
}

/** 只有本轮口令保护的夹具入口可以设故障；不能按新账号或新操作替换真实控制参数。 */
func (f *jointFixture) executionFixture(path, operation, mode string) (any, error) {
	if !f.controlMode {
		return nil, errors.New("control fixture disabled")
	}
	if _, err := uuid.Parse(operation); err != nil {
		return nil, err
	}
	s := f.controlState
	s.mu.Lock()
	defer s.mu.Unlock()
	switch path {
	case "/__fixture/control-mode":
		if mode != "drop_reply" && mode != "pause_reply" {
			return nil, errors.New("invalid reply fault")
		}
		if _, ok := s.modes[operation]; ok {
			return nil, errors.New("reply fault already set")
		}
		s.modes[operation] = mode
		if mode == "pause_reply" {
			s.gates[operation] = make(chan struct{})
		}
	case "/__fixture/release-control":
		if gate := s.gates[operation]; gate != nil {
			close(gate)
			delete(s.gates, operation)
		}
	}
	return map[string]int{"writes": s.writes[operation], "reads": s.reads[operation], "applied": s.applied[operation]}, nil
}

/** 首个分块已发后再等撤销，用于确认旧授权停止新分块；不借用新会话或另一次生成。 */
func (f *jointFixture) executionStream(w http.ResponseWriter, r *http.Request, mode string) {
	gate := make(chan struct{})
	f.mu.Lock()
	f.gates[mode] = gate
	f.mu.Unlock()
	w.Header().Set("Content-Type", "text/event-stream")
	_, _ = io.WriteString(w, "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg-result\",\"output_index\":0,\"content_index\":0,\"delta\":\"first-fragment\"}\n\n")
	w.(http.Flusher).Flush()
	select {
	case <-gate:
		_, _ = io.WriteString(w, "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg-result\",\"output_index\":0,\"content_index\":0,\"delta\":\"late-fragment\"}\n\n")
		f.resultUpstream(w, r, mode, true)
	case <-r.Context().Done():
		f.mu.Lock()
		f.disconnected[mode]++
		f.mu.Unlock()
	}
}

/** 收尾只关闭本夹具的故障门，避免失败后留下等待中的处理器。 */
func (f *jointFixture) stopExecutionControls() {
	s := f.controlState
	s.mu.Lock()
	defer s.mu.Unlock()
	for operation, gate := range s.gates {
		close(gate)
		delete(s.gates, operation)
	}
}
