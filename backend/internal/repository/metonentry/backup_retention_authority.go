//go:build meton_managed

package metonentry

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

const backupAuthorityPath = "/internal/operations/backup-retirement-authority"

type backupAuthorityQuery struct {
	FormatVersion      int    `json:"formatVersion"`
	RequestID          string `json:"requestId"`
	AuthorityReference string `json:"authorityReference"`
	Purpose            string `json:"purpose"`
	OperationID        string `json:"operationId"`
	TargetID           string `json:"targetId"`
	KeeperID           string `json:"keeperId"`
	PlanDigest         string `json:"planDigest"`
}

type backupAuthorityObservation struct {
	RequestID                   string    `json:"requestId"`
	Environment                 string    `json:"environment"`
	Source                      string    `json:"source"`
	AuthorityReference          string    `json:"authorityReference"`
	Purpose                     string    `json:"purpose"`
	OperationID                 string    `json:"operationId"`
	TargetID                    string    `json:"targetId"`
	KeeperID                    string    `json:"keeperId"`
	PlanDigest                  string    `json:"planDigest"`
	PersonID                    string    `json:"personId"`
	PersonVersion               int64     `json:"personVersion"`
	Generation                  int64     `json:"generation"`
	RecoveryState               string    `json:"recoveryState"`
	Until                       time.Time `json:"until"`
	ObservedAt                  time.Time `json:"observedAt"`
	IntentDigest                string    `json:"intentDigest"`
	AuditEventID                string    `json:"auditEventId"`
	DeletionAuthorized          *bool     `json:"deletionAuthorized"`
	RecoveryExecutionAuthorized *bool     `json:"recoveryExecutionAuthorized"`
}

type backupAuthorityReply struct {
	State       string                      `json:"state"`
	Observation *backupAuthorityObservation `json:"observation"`
}

type backupRetentionAuthority struct {
	configuration backupAuthorityConfiguration
	files         []backupAuthorityFile
	client        *http.Client
	transport     *http.Transport
	closed        atomic.Bool
}

var _ service.BackupRetentionAuthority = (*backupRetentionAuthority)(nil)

/** 意图沿 .NET 已定顺序编码；每次随机请求号只关联本次往返，不改变人员证明。 */
func (a *backupRetentionAuthority) digest(q backupAuthorityQuery) string {
	hash := sha256.Sum256([]byte(strings.Join([]string{q.Purpose, a.configuration.Environment, a.configuration.Source,
		q.AuthorityReference, q.OperationID, q.TargetID, q.KeeperID, q.PlanDigest}, "\n")))
	return hex.EncodeToString(hash[:])
}

/** 每次执行都问当前权威；断线、撤权及审计不明均不得回退到前次成功观察。 */
func (a *backupRetentionAuthority) Current(ctx context.Context, assertion string, intent service.BackupRetentionIntent) (service.BackupRetentionOperator, error) {
	empty := service.BackupRetentionOperator{}
	if a == nil || ctx.Err() != nil || !a.current() || !backupAuthorityAssertion(assertion) ||
		intent.Environment != a.configuration.Environment || intent.Source != a.configuration.Source ||
		!backupAuthorityID(intent.Operation) || !backupAuthorityPart(intent.Target, 128) || !backupAuthorityPart(intent.Keeper, 128) ||
		intent.Target == intent.Keeper || !backupAuthorityHash(intent.Digest) {
		return empty, service.ErrBackupRetirementUnavailable
	}
	destructive := false
	switch intent.Purpose {
	case "cash.backup.retirement.inspect.v1", "cash.backup.retirement.reconcile.v1":
	case "cash.backup.retirement.execute.v1", "cash.backup.retirement.resume.v1":
		destructive = true
	default:
		return empty, service.ErrBackupRetirementUnavailable
	}
	nonce, err := uuid.NewRandom()
	if err != nil {
		return empty, service.ErrBackupRetirementUnavailable
	}
	query := backupAuthorityQuery{1, nonce.String(), a.configuration.AuthorityReference, intent.Purpose, intent.Operation, intent.Target, intent.Keeper, intent.Digest}
	body, err := json.Marshal(query)
	if err != nil {
		return empty, service.ErrBackupRetirementUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	started := time.Now()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, a.configuration.Endpoint, bytes.NewReader(body))
	if err != nil {
		return empty, service.ErrBackupRetirementUnavailable
	}
	// 不提供可重放正文；观察失败由原协调显式重查，不由 HTTP 层偷偷重送。
	request.GetBody = nil
	request.Header.Set("Authorization", "Bearer "+assertion)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	response, err := a.client.Do(request)
	if err != nil {
		return empty, service.ErrBackupRetirementUnavailable
	}
	defer response.Body.Close()
	media, _, mediaErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if response.StatusCode != http.StatusOK || mediaErr != nil || media != "application/json" ||
		response.Header.Get("Content-Encoding") != "" || response.ContentLength > 16384 {
		return empty, service.ErrBackupRetirementUnavailable
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 16385))
	var reply backupAuthorityReply
	if err != nil || len(raw) > 16384 || metonexecution.DecodeStrict(raw, &reply) != nil || reply.State != "current" || reply.Observation == nil {
		return empty, service.ErrBackupRetirementUnavailable
	}
	observed := reply.Observation
	now := time.Now()
	if observed.RequestID != query.RequestID || observed.Environment != intent.Environment || observed.Source != intent.Source ||
		observed.AuthorityReference != query.AuthorityReference || observed.Purpose != intent.Purpose || observed.OperationID != intent.Operation ||
		observed.TargetID != intent.Target || observed.KeeperID != intent.Keeper || observed.PlanDigest != intent.Digest ||
		observed.IntentDigest != a.digest(query) || !backupAuthorityID(observed.PersonID) || !backupAuthorityID(observed.AuditEventID) ||
		observed.PersonVersion <= 0 || observed.Generation <= 0 || !observed.Until.After(now) ||
		observed.ObservedAt.Before(started.Add(-5*time.Second)) || observed.ObservedAt.After(now.Add(5*time.Second)) ||
		(observed.RecoveryState != "active" && observed.RecoveryState != "closed") ||
		(destructive && observed.RecoveryState != "active") || observed.DeletionAuthorized == nil || *observed.DeletionAuthorized != destructive ||
		observed.RecoveryExecutionAuthorized == nil || *observed.RecoveryExecutionAuthorized || ctx.Err() != nil || !a.current() {
		return empty, service.ErrBackupRetirementUnavailable
	}
	return service.BackupRetentionOperator{Environment: observed.Environment, Source: observed.Source, Person: observed.PersonID,
		Generation: observed.Generation, Version: observed.PersonVersion, Until: observed.Until}, nil
}

/** 部署文件变化后永久退役本实例；换回旧文件不能使缓存的连接和证书重新生效。 */
func (a *backupRetentionAuthority) current() bool {
	if a.closed.Load() {
		return false
	}
	for _, file := range a.files {
		current, _, err := readBackupAuthorityFile(file.path, file.limit)
		if err != nil || current.hash != file.hash || !file.same(current) {
			a.close()
			return false
		}
	}
	return !a.closed.Load()
}

/** 只关闭本适配的连接；重复释放不影响其他服务或后续新装配的实例。 */
func (a *backupRetentionAuthority) close() {
	if a.closed.CompareAndSwap(false, true) {
		a.transport.CloseIdleConnections()
	}
}

/** 只接受规范 UUID，防止跨语言对同一原操作形成不同摘要。 */
func backupAuthorityID(value string) bool {
	id, err := uuid.Parse(value)
	return err == nil && id != uuid.Nil && id.String() == value
}

/** 字符与 .NET 契约相同，不允许换行或其他分隔符混进意图。 */
func backupAuthorityPart(value string, limit int) bool {
	if len(value) == 0 || len(value) > limit {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

/** 固定小写摘要；不能用空值或其他长度的占位值取得当前观察。 */
func backupAuthorityHash(value string) bool {
	raw, err := hex.DecodeString(value)
	return err == nil && len(raw) == 32 && hex.EncodeToString(raw) == value
}

/** Bearer 只放在请求头，不接受空白、控制字符或将其写入日志。 */
func backupAuthorityAssertion(value string) bool {
	if len(value) == 0 || len(value) > 8185 {
		return false
	}
	for _, c := range value {
		if c < 33 || c > 126 {
			return false
		}
	}
	return true
}
