//go:build meton_managed

// Package metontransport 将来源数据库的首次发送权限制为一次实际网络尝试。
package metontransport

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
)

var ErrUnavailable = errors.New("original model send unavailable")

// Once 不保留 Bearer 或模型正文。下一层必须是无内部重试的实际 HTTP Transport。
type Once struct {
	verified *metondispatch.Verified
	claim    func(context.Context) (bool, error)
	prepare  func(context.Context, *http.Request, []byte) (bool, error)
	next     http.RoundTripper
	used     atomic.Bool
	original context.Context
	subject  Subject
	observe  func(*http.Response)
}

/** New 只能消费已核验的原上下文；查询回执和零值不能转换为一次执行。 */
func New(verified *metondispatch.Verified, claim func(context.Context) (bool, error), next http.RoundTripper) (*Once, error) {
	if !verified.Current(time.Now()) || claim == nil || next == nil {
		return nil, ErrUnavailable
	}
	return &Once{verified: verified, claim: claim, next: next}, nil
}

/** RoundTrip 领取开始后永不恢复进程内资格；领取回应未知也不会自动再领取或释放来源 H。 */
func (o *Once) RoundTrip(request *http.Request) (*http.Response, error) {
	if o == nil {
		return nil, ErrUnavailable
	}
	return o.roundTrip(request, o.next)
}

/** 同一个原请求允许借不同账户的连接池构造客户端，但所有客户端争用同一份资格。 */
func (o *Once) roundTrip(request *http.Request, next http.RoundTripper) (*http.Response, error) {
	handed := false
	defer func() {
		if !handed && request != nil && request.Body != nil {
			_ = request.Body.Close()
		}
	}()
	if o == nil {
		return nil, ErrUnavailable
	}
	if !o.used.CompareAndSwap(false, true) {
		if o.verified != nil {
			c := o.verified.Context()
			metonobserve.Record(metonobserve.Scope{Environment: c.Environment, Source: c.Source, Epoch: c.Epoch}, metonobserve.RepeatAttempt)
		}
		return nil, ErrUnavailable
	}
	if next == nil || request == nil || request.Method != "POST" || request.Body == nil ||
		request.ContentLength <= 0 || !o.current() || request.Context().Err() != nil {
		return nil, ErrUnavailable
	}
	// 原生转发为收尾使用 WithoutCancel，不能因此让用户已取消的请求继续排队或发送。
	ctx, cancel := context.WithDeadline(request.Context(), time.UnixMilli(o.verified.Context().ValidUntilMS))
	stop := func() bool { return false }
	if o.original != nil {
		stop = context.AfterFunc(o.original, cancel)
	}
	cleanup := func() { stop(); cancel() }
	out := request.Clone(ctx)
	var first bool
	var err error
	if o.prepare != nil {
		// 先固定将发送的字节，回调的改写或原生 GetBody 不能在预占之后换掉它。
		if request.ContentLength > 1024*1024 {
			cleanup()
			return nil, ErrUnavailable
		}
		var body []byte
		body, err = io.ReadAll(io.LimitReader(request.Body, 1024*1024+1))
		_ = request.Body.Close()
		if err != nil || int64(len(body)) != request.ContentLength {
			cleanup()
			return nil, ErrUnavailable
		}
		out.Body = io.NopCloser(bytes.NewReader(body))
		candidate := out.Clone(ctx)
		candidate.Body = nil
		candidate.GetBody = nil
		first, err = o.prepare(ctx, candidate, bytes.Clone(body))
	} else if o.claim != nil {
		first, err = o.claim(ctx)
	}
	if err != nil || !first || !o.current() || ctx.Err() != nil {
		cleanup()
		return nil, ErrUnavailable
	}
	// 即使上层 HTTP Client 或供应账户切换再次调用，本对象也不会执行第二次网络请求。
	// 清除可重放体与幂等头，防止标准 Transport 在已经写出后自行重试 POST。
	out.GetBody = nil
	for actual := range out.Header {
		for _, name := range []string{"Idempotency-Key", "X-Idempotency-Key", metondispatch.ContextHeader, metondispatch.ProofHeader} {
			if strings.EqualFold(actual, name) {
				delete(out.Header, actual)
			}
		}
	}
	handed = true
	response, err := next.RoundTrip(out)
	if err != nil || response == nil || response.Body == nil {
		cleanup()
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		if err == nil {
			err = ErrUnavailable
		}
		if o.observe != nil {
			o.observe(nil)
		}
		return nil, err
	}
	response.Body = &boundBody{ReadCloser: response.Body, cleanup: cleanup}
	if o.observe != nil {
		o.observe(response)
	}
	return response, nil
}

func (o *Once) current() bool {
	return o != nil && o.verified.Current(time.Now()) && (o.original == nil || o.original.Err() == nil)
}

/** 实际出站沿原请求截止；读取完成或提前关闭时都释放监听，不等待后台超时。 */
type boundBody struct {
	io.ReadCloser
	cleanup func()
	once    sync.Once
}

func (b *boundBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if err != nil {
		b.once.Do(b.cleanup)
	}
	return n, err
}
func (b *boundBody) Close() error {
	b.once.Do(b.cleanup)
	return b.ReadCloser.Close()
}
