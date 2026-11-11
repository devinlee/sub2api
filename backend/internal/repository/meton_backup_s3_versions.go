//go:build meton_managed

package repository

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

var _ service.RetainedBackupObjectStore = (*S3BackupStore)(nil)

/** 只改变本次受控版本操作；原客户端的上传、下载及普通构建保持原重试配置。 */
func backupVersionAttempt(options *s3.Options) {
	options.Retryer = aws.NopRetryer{}
	options.RetryMaxAttempts = 1
	// SDK 默认允许 307/308；跳转可能去掉 versionId，不能把原版本命令重定向成按名操作。
	var client http.Client
	switch original := options.HTTPClient.(type) {
	case *awshttp.BuildableClient:
		transport := original.GetTransport()
		// 此处按操作克隆，关闭空闲复用，避免每次查询遗留一个独立连接池。
		transport.DisableKeepAlives = true
		client.Transport, client.Timeout = transport, original.GetTimeout()
	case *http.Client:
		client = *original
	default:
		options.HTTPClient = unavailableBackupVersionHTTP{}
		return
	}
	client.Jar = nil
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	options.HTTPClient = &client
}

type unavailableBackupVersionHTTP struct{}

/** 无法关闭跳转的自定义传输不取得受控对象操作能力。 */
func (unavailableBackupVersionHTTP) Do(*http.Request) (*http.Response, error) {
	return nil, service.ErrBackupRetirementUnavailable
}

/** 版本是对象端的不可替代身份；无版本或空对象不能成为可退役的完整备份。 */
func (s *S3BackupStore) validBackupVersion(ctx context.Context, v service.BackupObjectVersion) bool {
	return ctx.Err() == nil && s != nil && s.client != nil && s.bucket != "" &&
		validBackupObjectKey(v.Key) && v.VersionID != "" && v.VersionID != "null" &&
		len(v.VersionID) <= 1024 && utf8.ValidString(v.VersionID) && strings.TrimSpace(v.VersionID) == v.VersionID &&
		!strings.ContainsAny(v.VersionID, "\x00\r\n") && v.Size > 0
}

/** 不规范化对象键，避免把不同对象折叠成同一目标。 */
func validBackupObjectKey(key string) bool {
	return key != "" && len(key) <= 1024 && utf8.ValidString(key) && !strings.ContainsRune(key, 0)
}

/** HEAD 只用于首次固定当前版本；任何 HEAD 错误均不作为对象不存在的证明。 */
func (s *S3BackupStore) CurrentVersion(ctx context.Context, key string) (service.BackupObjectVersion, error) {
	if ctx.Err() != nil || s == nil || s.client == nil || s.bucket == "" || !validBackupObjectKey(key) {
		return service.BackupObjectVersion{}, service.ErrBackupRetirementUnavailable
	}
	result, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: &s.bucket, Key: &key}, backupVersionAttempt)
	if err != nil {
		return service.BackupObjectVersion{}, fmt.Errorf("S3 backup version metadata: %w", err)
	}
	v := service.BackupObjectVersion{Key: key, VersionID: aws.ToString(result.VersionId), Size: aws.ToInt64(result.ContentLength)}
	if !s.validBackupVersion(ctx, v) || aws.ToBool(result.DeleteMarker) {
		return service.BackupObjectVersion{}, service.ErrBackupRetirementUnavailable
	}
	return v, nil
}

/** 读取原计划版本的完整内容；错误响应的正文也必须释放，不返回最新版本替代品。 */
func (s *S3BackupStore) ReadVersion(ctx context.Context, v service.BackupObjectVersion) (io.ReadCloser, error) {
	if !s.validBackupVersion(ctx, v) {
		return nil, service.ErrBackupRetirementUnavailable
	}
	result, err := s.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: &s.bucket, Key: &v.Key, VersionId: &v.VersionID,
	}, backupVersionAttempt)
	if err != nil {
		return nil, fmt.Errorf("S3 backup version read: %w", err)
	}
	if ctx.Err() != nil || result.Body == nil || aws.ToString(result.VersionId) != v.VersionID ||
		aws.ToBool(result.DeleteMarker) || result.ContentLength == nil || *result.ContentLength != v.Size ||
		aws.ToString(result.ContentRange) != "" {
		if result.Body != nil {
			_ = result.Body.Close()
		}
		return nil, service.ErrBackupRetirementUnavailable
	}
	return result.Body, nil
}

/** 只认版本 GET 的明确缺失；HEAD 的通用 404 无法区分缺桶、缺权限及缺版本。 */
func missingBackupVersion(err error) bool {
	var api smithy.APIError
	var status interface{ HTTPStatusCode() int }
	return errors.As(err, &api) && errors.As(err, &status) &&
		api.ErrorCode() == "NoSuchVersion" && status.HTTPStatusCode() == 404
}

/** 用一个字节核对原版本及总长度，避免为存在性查询重新下载整个备份。 */
func (s *S3BackupStore) VersionExists(ctx context.Context, v service.BackupObjectVersion) (bool, error) {
	if !s.validBackupVersion(ctx, v) {
		return false, service.ErrBackupRetirementUnavailable
	}
	result, err := s.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: &s.bucket, Key: &v.Key, VersionId: &v.VersionID, Range: aws.String("bytes=0-0"),
	}, backupVersionAttempt)
	if err != nil {
		if ctx.Err() == nil && missingBackupVersion(err) {
			return false, nil
		}
		return false, fmt.Errorf("S3 backup version presence: %w", err)
	}
	if result.Body == nil {
		return false, service.ErrBackupRetirementUnavailable
	}
	defer result.Body.Close()
	if aws.ToString(result.VersionId) != v.VersionID || aws.ToBool(result.DeleteMarker) ||
		aws.ToInt64(result.ContentLength) != 1 || aws.ToString(result.ContentRange) != fmt.Sprintf("bytes 0-0/%d", v.Size) {
		return false, service.ErrBackupRetirementUnavailable
	}
	data, err := io.ReadAll(io.LimitReader(result.Body, 2))
	if err != nil || len(data) != 1 || ctx.Err() != nil {
		return false, service.ErrBackupRetirementUnavailable
	}
	return true, nil
}

/** 只能增加无自动到期的原版本保护；写入受理仍须由 VersionProtected 单独复验。 */
func (s *S3BackupStore) ProtectVersion(ctx context.Context, v service.BackupObjectVersion) error {
	if !s.validBackupVersion(ctx, v) {
		return service.ErrBackupRetirementUnavailable
	}
	_, err := s.client.PutObjectLegalHold(ctx, &s3.PutObjectLegalHoldInput{
		Bucket: &s.bucket, Key: &v.Key, VersionId: &v.VersionID,
		LegalHold: &types.ObjectLockLegalHold{Status: types.ObjectLockLegalHoldStatusOn},
	}, backupVersionAttempt)
	if err != nil {
		return fmt.Errorf("S3 backup version protection: %w", err)
	}
	return ctx.Err()
}

/** S3 此响应没有版本字段，依指定版本请求取 ON；缺失、未知状态或不支持均不算保护。 */
func (s *S3BackupStore) VersionProtected(ctx context.Context, v service.BackupObjectVersion) (bool, error) {
	if !s.validBackupVersion(ctx, v) {
		return false, service.ErrBackupRetirementUnavailable
	}
	result, err := s.client.GetObjectLegalHold(ctx, &s3.GetObjectLegalHoldInput{
		Bucket: &s.bucket, Key: &v.Key, VersionId: &v.VersionID,
	}, backupVersionAttempt)
	if err != nil {
		return false, fmt.Errorf("S3 backup version protection query: %w", err)
	}
	if ctx.Err() != nil || result.LegalHold == nil {
		return false, service.ErrBackupRetirementUnavailable
	}
	switch result.LegalHold.Status {
	case types.ObjectLockLegalHoldStatusOn:
		return true, nil
	case types.ObjectLockLegalHoldStatusOff:
		return false, nil
	default:
		return false, service.ErrBackupRetirementUnavailable
	}
}

/** 永远指定原版本且不设置治理绕过；应答丢失或身份不符交回未知，不在适配层重发。 */
func (s *S3BackupStore) DeleteVersion(ctx context.Context, v service.BackupObjectVersion) error {
	if !s.validBackupVersion(ctx, v) {
		return service.ErrBackupRetirementUnavailable
	}
	result, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: &s.bucket, Key: &v.Key, VersionId: &v.VersionID,
	}, backupVersionAttempt)
	if err != nil {
		return fmt.Errorf("S3 backup version delete: %w", err)
	}
	if ctx.Err() != nil || aws.ToString(result.VersionId) != v.VersionID || aws.ToBool(result.DeleteMarker) {
		return service.ErrBackupRetirementUnavailable
	}
	return nil
}
