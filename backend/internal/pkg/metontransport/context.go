//go:build meton_managed

package metontransport

import (
	"context"
	"net/http"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
)

type dispatchContextKey struct{}
type providerContextKey struct{}

/** ProviderAccount 只读取实际连接池带入的供应账户，不从 HTTP 头或原 Meton 用户推断。 */
func ProviderAccount(ctx context.Context) int64 {
	if ctx == nil {
		return 0
	}
	id, _ := ctx.Value(providerContextKey{}).(int64)
	return id
}

// Subject 是原生鉴权与部署路由交出的编号，不能从客户端上下文头填入。
type Subject struct{ User, Key, Group int64 }

/** BindAuthenticated 仅由来源入口装配；预检只认同一个已认证原生主体，不能换用户或组复用。 */
func BindAuthenticated(ctx context.Context, proof *metondispatch.Verified, subject Subject, prepare func(context.Context, *http.Request, []byte) (bool, error)) (context.Context, error) {
	if subject.User < 1 || subject.Key < 1 || subject.Group < 1 {
		return nil, ErrUnavailable
	}
	boundCtx, err := BindPrepared(ctx, proof, prepare)
	if err != nil {
		return nil, err
	}
	bound(boundCtx).subject = subject
	return boundCtx, nil
}

/** BindObservedAuthenticated 把唯一实际尝试的响应交给原请求观察器；nil 响应仅表示网络结果未知。 */
func BindObservedAuthenticated(ctx context.Context, proof *metondispatch.Verified, subject Subject,
	prepare func(context.Context, *http.Request, []byte) (bool, error), observe func(*http.Response)) (context.Context, error) {
	if observe == nil {
		return nil, ErrUnavailable
	}
	boundCtx, err := BindAuthenticated(ctx, proof, subject, prepare)
	if err != nil {
		return nil, err
	}
	bound(boundCtx).observe = observe
	return boundCtx, nil
}

/** Admitted 只放行到原生文本调度；真正网络仍必须取得来源库的预占与首次发送提交。 */
func Admitted(ctx context.Context, subject Subject) bool {
	gate := bound(ctx)
	return gate.current() && gate.prepare != nil && gate.subject == subject && subject.User > 0 && subject.Key > 0 && subject.Group > 0
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

/** Bind 由已认证的来源受理装配；保存原取消边界，身份与发送权都不从客户端头恢复。 */
func Bind(ctx context.Context, proof *metondispatch.Verified, claim func(context.Context) (bool, error)) (context.Context, error) {
	if ctx == nil || ctx.Err() != nil || !proof.Current(time.Now()) || claim == nil || bound(ctx) != nil {
		return nil, ErrUnavailable
	}
	return context.WithValue(ctx, dispatchContextKey{}, &Once{verified: proof, claim: claim, original: ctx}), nil
}

/** BindPrepared 在实际原生出站内容确定后才报价、预占和领取；回调看的是独立快照。 */
func BindPrepared(ctx context.Context, proof *metondispatch.Verified, prepare func(context.Context, *http.Request, []byte) (bool, error)) (context.Context, error) {
	if ctx == nil || ctx.Err() != nil || !proof.Current(time.Now()) || prepare == nil || bound(ctx) != nil {
		return nil, ErrUnavailable
	}
	return context.WithValue(ctx, dispatchContextKey{}, &Once{verified: proof, prepare: prepare, original: ctx}), nil
}

func bound(ctx context.Context) *Once {
	if ctx == nil {
		return nil
	}
	gate, _ := ctx.Value(dispatchContextKey{}).(*Once)
	return gate
}

/** Current 只核验本次受理上下文，不能代替数据库中的首次发送裁决。 */
func Current(ctx context.Context) bool { return bound(ctx).current() }

/** Bound 在截止后仍保留原调用属性，仅用于禁止回退，绝不据此放行新发送。 */
func Bound(ctx context.Context) bool { return bound(ctx) != nil }

/** Client 只包装原生标准 Transport；内部重试不明的包装器或插件不能伪装成安全出口。 */
func Client(client *http.Client, request *http.Request) (*http.Client, error) {
	return clientForProvider(client, request, 0)
}

/** ClientForProvider 在实际发送前携带原生供应账户，构造多个客户端不会提前改写共享资格。 */
func ClientForProvider(client *http.Client, request *http.Request, account int64) (*http.Client, error) {
	if account < 1 {
		return nil, ErrUnavailable
	}
	return clientForProvider(client, request, account)
}

func clientForProvider(client *http.Client, request *http.Request, account int64) (*http.Client, error) {
	if client == nil || request == nil {
		return nil, ErrUnavailable
	}
	gate := bound(request.Context())
	if !gate.current() {
		return nil, ErrUnavailable
	}
	next := client.Transport
	if next == nil {
		next = http.DefaultTransport
	}
	if transport, ok := next.(*http.Transport); !ok || transport == nil {
		return nil, ErrUnavailable
	}
	clone := *client
	clone.Jar = nil
	clone.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	clone.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if account > 0 {
			r = r.WithContext(context.WithValue(r.Context(), providerContextKey{}, account))
		}
		return gate.roundTrip(r, next)
	})
	return &clone, nil
}
