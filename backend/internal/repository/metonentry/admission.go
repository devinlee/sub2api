//go:build meton_managed

// Package metonentry 装配来源入口认证、原生调度身份及最终正文预占，不另建钱包或模型执行器。
package metonentry

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"reflect"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metondispatch"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonresult"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metontransport"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type KeyReader interface {
	GetByKey(context.Context, string) (*service.APIKey, error)
}
type GroupReader interface {
	GetByID(context.Context, int64) (*service.Group, error)
}
type Route struct {
	Group    int64
	Profiles []*metonexecution.Profile
}
type Admission struct {
	Control           *service.MetonModelControl
	verifier          *metondispatch.Verifier
	keys              KeyReader
	groups            GroupReader
	reserve, send     *metonledger.TextLedger
	complete, inspect *metonledger.TextLedger
	routes            map[string]Route
	captureProvider   bool
}

/** New 固定部署路由，不接受请求指定 Group 或运行中追加受信 Profile。 */
func New(verifier *metondispatch.Verifier, keys KeyReader, groups GroupReader, reserve, send, complete, inspect *metonledger.TextLedger, routes []Route) (*Admission, error) {
	if verifier == nil || keys == nil || groups == nil || len(routes) == 0 {
		return nil, service.ErrMetonClosed
	}
	seenPorts := map[*metonledger.TextLedger]bool{}
	for _, port := range []*metonledger.TextLedger{reserve, send, complete, inspect} {
		if port == nil || seenPorts[port] {
			return nil, service.ErrMetonClosed
		}
		seenPorts[port] = true
	}
	a := &Admission{verifier: verifier, keys: keys, groups: groups, reserve: reserve, send: send, complete: complete, inspect: inspect, routes: map[string]Route{}}
	for _, r := range routes {
		if r.Group < 1 || len(r.Profiles) == 0 {
			return nil, service.ErrMetonClosed
		}
		first := r.Profiles[0].Spec()
		id := first.Protocol + ":" + first.Model
		if _, exists := a.routes[id]; exists {
			return nil, service.ErrMetonClosed
		}
		seen := map[string]bool{}
		for _, p := range r.Profiles {
			s := p.Spec()
			target := s.Target + ":" + s.WireModel
			if p == nil || s.Protocol != first.Protocol || s.Model != first.Model || s.OutputWindow != first.OutputWindow || seen[target] {
				return nil, service.ErrMetonClosed
			}
			seen[target] = true
		}
		a.routes[id] = Route{Group: r.Group, Profiles: append([]*metonexecution.Profile(nil), r.Profiles...)}
	}
	return a, nil
}

/** oneHeader 拒绝重复及大小写别名；不要让入口校验与原生处理器取到两份不同凭据。 */
func oneHeader(h http.Header, name string) (string, bool) {
	count := 0
	value := ""
	for actual, values := range h {
		if strings.EqualFold(actual, name) {
			count += len(values)
			if len(values) == 1 {
				value = values[0]
			}
		}
	}
	return value, count == 1 && value != "" && !strings.ContainsAny(value, "\r\n")
}

/** Admit 先核验网关证明，再沿 S1 的主库 Key 鉴权；当前余额由派发前来源事务裁定。 */
func (a *Admission) Admit(r *http.Request) (*http.Request, *service.APIKey, error) {
	if a == nil || r == nil || r.URL == nil || r.Body == nil || r.Context().Err() != nil || r.Method != "POST" ||
		(r.URL.Path != "/v1/responses" && r.URL.Path != "/v1/chat/completions") || r.URL.RawPath != "" || r.URL.RawQuery != "" || r.URL.ForceQuery || r.URL.Fragment != "" ||
		r.Header.Get("Content-Encoding") != "" || len(r.TransferEncoding) > 0 || r.ContentLength > 256*1024 {
		return nil, nil, service.ErrMetonClosed
	}
	auth, ok := oneHeader(r.Header, "Authorization")
	if !ok || !strings.HasPrefix(auth, "Bearer ") || len(auth) > 16391 {
		return nil, nil, service.ErrMetonClosed
	}
	secret := strings.TrimPrefix(auth, "Bearer ")
	if secret == "" || strings.ContainsAny(secret, " \t\r\n") {
		return nil, nil, service.ErrMetonClosed
	}
	header, ok := oneHeader(r.Header, metondispatch.ContextHeader)
	if !ok {
		return nil, nil, service.ErrMetonClosed
	}
	proof, ok := oneHeader(r.Header, metondispatch.ProofHeader)
	if !ok {
		return nil, nil, service.ErrMetonClosed
	}
	contentType, ok := oneHeader(r.Header, "Content-Type")
	if !ok {
		return nil, nil, service.ErrMetonClosed
	}
	media, params, err := mime.ParseMediaType(contentType)
	if err != nil || media != "application/json" || len(params) > 1 || len(params) == 1 && !strings.EqualFold(params["charset"], "utf-8") {
		return nil, nil, service.ErrMetonClosed
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 256*1024+1))
	_ = r.Body.Close()
	if err != nil || len(body) == 0 || len(body) > 256*1024 || r.ContentLength >= 0 && r.ContentLength != int64(len(body)) {
		return nil, nil, service.ErrMetonClosed
	}
	v, err := a.verifier.Verify(r.Method, r.URL.Path, header, proof, body, []byte(secret), time.Now())
	if err != nil {
		return nil, nil, service.ErrMetonClosed
	}
	c := v.Context()
	route, ok := a.routes[c.Protocol+":"+c.Model]
	if !ok || route.Profiles[0].ValidateOriginal(body) != nil {
		return nil, nil, service.ErrMetonClosed
	}
	// 复用 S1 的 readCurrentManagedKey：每次到主库检查凭据、关停和恢复栅栏，不信任缓存授权。
	key, err := a.keys.GetByKey(r.Context(), secret)
	if err != nil || key == nil || key.ID < 1 || key.User == nil || key.UserID != key.User.ID || !key.IsActive() || key.IsExpired() || !key.User.IsActive() || key.User.DeletedAt != nil ||
		key.User.Concurrency < 1 || key.GroupID != nil || key.Group != nil || len(key.IPWhitelist) > 0 || len(key.IPBlacklist) > 0 {
		return nil, nil, service.ErrMetonClosed
	}
	// 托管 Key 共用来源账户资金；未接入来源事务的原生金额限制不能被静默忽略。
	if key.Quota != 0 || key.QuotaUsed != 0 || key.RateLimit5h != 0 || key.RateLimit1d != 0 || key.RateLimit7d != 0 ||
		key.Usage5h != 0 || key.Usage1d != 0 || key.Usage7d != 0 {
		return nil, nil, service.ErrMetonClosed
	}
	group, err := a.groups.GetByID(r.Context(), route.Group)
	if err != nil || group == nil || group.ID != route.Group || group.Status != service.StatusActive || group.Platform != service.PlatformOpenAI || group.IsSubscriptionType() ||
		group.FallbackGroupID != nil || group.FallbackGroupIDOnInvalidRequest != nil {
		return nil, nil, service.ErrMetonClosed
	}
	nativeKey, nativeUser, nativeGroup := *key, *key.User, *group
	nativeKey.User = &nativeUser
	nativeKey.Group = &nativeGroup
	nativeKey.GroupID = &nativeGroup.ID
	actualKey := metonledger.SessionKey{ID: key.ID, Fingerprint: c.KeyDigest}
	var activeHold *metonledger.Hold
	var activeQuote *metonexecution.Quote
	var codexStream bool
	ctx, err := metontransport.BindObservedAuthenticated(r.Context(), v, metontransport.Subject{User: key.UserID, Key: key.ID, Group: route.Group},
		func(ctx context.Context, request *http.Request, actual []byte) (bool, error) {
			var quote *metonexecution.Quote
			for _, p := range route.Profiles {
				candidate, e := p.Quote(v, request, actual)
				if e == nil {
					if quote != nil {
						return false, service.ErrMetonClosed
					}
					quote = candidate
				}
			}
			if quote == nil {
				return false, service.ErrMetonClosed
			}
			var hold *metonledger.Hold
			var e error
			if a.captureProvider {
				binding, err := metonprovider.Capture(metontransport.ProviderAccount(ctx), request.Header, quote.Record().WireProtocol, actual)
				if err != nil {
					return false, service.ErrMetonClosed
				}
				hold, e = a.reserve.ReserveProviderExecution(ctx, v, actualKey, quote, binding)
			} else {
				hold, e = a.reserve.ReserveExecution(ctx, v, actualKey, quote)
			}
			if e != nil {
				return false, e
			}
			first, e := a.send.ClaimExecution(ctx, v, actualKey, hold, quote)
			if e == nil && first {
				activeHold, activeQuote = hold, quote
				codexStream = a.captureProvider && metonresult.CodexStreamRequest(request, actual)
			}
			return first, e
		}, func(response *http.Response) {
			// 回调只有唯一网络尝试能到达，规格和来源 H 已由同一 prepare 固定，不从响应头重建归属。
			if activeHold == nil || activeQuote == nil {
				return
			}
			spec := activeQuote.Record()
			var reader *metonresult.Reader
			finish := func(observed metonresult.Snapshot) {
				a.recordCompletion(r.Context(), v, activeHold, activeQuote, observed)
				// 原签收先行。只记原请求和固定分类，诊断不参与结算或再次派发。
				if observed.FeeReady && reader != nil && reader.SupplierAttributionDigest() != "" {
					slog.Info("meton_supplier_attribution", "source_request", activeHold.Origin.SourceRequestID,
						"body_sha256", observed.BodySHA256, "attribution_sha256", reader.SupplierAttributionDigest(), "customer_price", activeHold.PriceVersion)
				}
				if !observed.FeeReady && reader != nil {
					slog.Warn("meton_text_incomplete_observation", "source_request", activeHold.Origin.SourceRequestID,
						"reason", reader.IncompleteReason(observed), "encoding", metonresult.EncodingClass(response.Header.Get("Content-Encoding")),
						"http_status", response.StatusCode, "read_end", observed.ReadEnd, "declared_media", reader.DeclaredMedia())
					if codexStream && observed.Terminal != "" {
						slog.Warn("meton_text_meter_shape", "source_request", activeHold.Origin.SourceRequestID,
							"body_sha256", observed.BodySHA256, "meter_shape", reader.MeterDiagnostic())
					}
				}
			}
			if response == nil {
				finish(metonresult.Unavailable(spec.WireProtocol))
				return
			}
			price := metonresult.AcceptedTextPrice{Environment: activeHold.Origin.Environment, Source: activeHold.Origin.Source,
				Model: activeHold.Estimate.Model, Unit: activeHold.Unit, Version: activeHold.PriceVersion}
			observed, e := metonresult.NewPricedSourceResponse(response, spec.WireProtocol, spec.WireModel, codexStream, price, finish)
			if e != nil {
				finish(metonresult.Unavailable(spec.WireProtocol))
				return
			}
			reader = observed
			response.Body = observed
		})
	if err != nil {
		return nil, nil, service.ErrMetonClosed
	}
	accepted := r.Clone(ctx)
	accepted.Body = io.NopCloser(bytes.NewReader(body))
	accepted.ContentLength = int64(len(body))
	accepted.GetBody = nil
	accepted.Header.Del(metondispatch.ContextHeader)
	accepted.Header.Del(metondispatch.ProofHeader)
	return accepted, &nativeKey, nil
}

/** recordCompletion 收尾只给原事实入账，不延长网络执行；丢回执后只查一次，不重交或补发。 */
func (a *Admission) recordCompletion(original context.Context, v *metondispatch.Verified, hold *metonledger.Hold, quote *metonexecution.Quote, observed metonresult.Snapshot) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(original), 5*time.Second)
	_, err := a.complete.CompleteExecution(ctx, v, hold, quote, observed)
	cancel()
	if err == nil {
		return
	}
	// 读取使用独立权限与新的短期限，不因原用户取消而丢掉已提交的费用，也不继承写入许可。
	ctx, cancel = context.WithTimeout(context.WithoutCancel(original), 5*time.Second)
	defer cancel()
	result, queryErr := a.inspect.FindExecution(ctx, hold.Origin)
	if queryErr == nil && reflect.DeepEqual(result.Observation, observed) {
		slog.Info("meton_text_completion_reconciled", "source_request", hold.Origin.SourceRequestID)
		return
	}
	// 原请求与 H 留在来源库待核对。错误对象可能含连接信息，日志只记录固定原因及原请求号。
	slog.Warn("meton_text_completion_pending", "source_request", hold.Origin.SourceRequestID, "reason", "original_result_unconfirmed")
}
