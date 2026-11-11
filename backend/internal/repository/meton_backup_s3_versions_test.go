//go:build unit && meton_managed

package repository

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

/** 通过原工厂使用固定 AWS SDK；只有远端协议由本机 HTTP 夹具提供。 */
func backupVersionHTTPStore(t *testing.T, handler http.HandlerFunc) service.RetainedBackupObjectStore {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	store, err := NewS3BackupStoreFactory()(context.Background(), &service.BackupS3Config{
		Endpoint: server.URL, Region: "auto", Bucket: "retirement-test", ForcePathStyle: true,
		AccessKeyID: "fixture-access", SecretAccessKey: "fixture-secret",
	})
	require.NoError(t, err)
	retained, ok := store.(service.RetainedBackupObjectStore)
	require.True(t, ok)
	return retained
}

/** 保留实际 HTTP 状态和 S3 错误码，不能只模拟一个 Go 错误字符串。 */
func backupVersionHTTPError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/xml")
	w.WriteHeader(status)
	fmt.Fprintf(w, "<Error><Code>%s</Code><Message>fixture</Message></Error>", code)
}

/** 同名新版本、原字节读取和保留版本保护经真实 SDK 的路径及查询参数往返。 */
func TestMetonS3BackupVersions_ExactContentAndHold(t *testing.T) {
	ctx := context.Background()
	key, version := "backup/a +%.gz", "original+/%=?"
	keeperKey := "backup/keeper.gz"
	type object struct {
		body string
		hold bool
	}
	var mu sync.Mutex
	objects := map[string]map[string]*object{
		key: {version: {body: "one"}}, keeperKey: {"keeper-v1": {body: "one"}},
	}
	latest := map[string]string{key: version, keeperKey: "keeper-v1"}
	var deletes, holds int
	store := backupVersionHTTPStore(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		objectKey := strings.TrimPrefix(r.URL.Path, "/retirement-test/")
		id := r.URL.Query().Get("versionId")
		if !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 ") ||
			r.Header.Get("X-Amz-Bypass-Governance-Retention") != "" || (r.Method != http.MethodHead && id == "") {
			t.Errorf("版本请求丢失身份、绑定或携带了绕过参数：%s %s", r.Method, r.URL)
			backupVersionHTTPError(w, 400, "InvalidRequest")
			return
		}
		if r.Method == http.MethodHead {
			id = latest[objectKey]
		}
		o := objects[objectKey][id]
		if o == nil {
			backupVersionHTTPError(w, 404, "NoSuchVersion")
			return
		}
		if r.URL.Query().Has("legal-hold") {
			if r.Method == http.MethodPut {
				var hold struct {
					Status string `xml:"Status"`
				}
				if err := xml.NewDecoder(r.Body).Decode(&hold); err != nil || hold.Status != "ON" {
					t.Errorf("只允许保护 ON：%v", err)
					backupVersionHTTPError(w, 400, "InvalidRequest")
					return
				}
				o.hold = true
				holds++
				w.WriteHeader(200)
				return
			}
			status := "OFF"
			if o.hold {
				status = "ON"
			}
			fmt.Fprintf(w, "<LegalHold><Status>%s</Status></LegalHold>", status)
			return
		}
		w.Header().Set("X-Amz-Version-Id", id)
		switch r.Method {
		case http.MethodHead:
			w.Header().Set("Content-Length", fmt.Sprint(len(o.body)))
		case http.MethodGet:
			if r.Header.Get("Range") == "bytes=0-0" {
				w.Header().Set("Content-Length", "1")
				w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-0/%d", len(o.body)))
				w.WriteHeader(206)
				io.WriteString(w, o.body[:1])
			} else {
				io.WriteString(w, o.body)
			}
		case http.MethodDelete:
			deletes++
			if o.hold {
				backupVersionHTTPError(w, 403, "AccessDenied")
				return
			}
			delete(objects[objectKey], id)
			w.WriteHeader(204)
		default:
			t.Errorf("未预期请求：%s", r.Method)
			w.WriteHeader(400)
		}
	})
	original, err := store.CurrentVersion(ctx, key)
	require.NoError(t, err)
	require.Equal(t, service.BackupObjectVersion{Key: key, VersionID: version, Size: 3}, original)
	read, err := store.ReadVersion(ctx, original)
	require.NoError(t, err)
	raw, err := io.ReadAll(read)
	require.NoError(t, err)
	require.NoError(t, read.Close())
	require.Equal(t, "one", string(raw))
	keeper, err := store.CurrentVersion(ctx, keeperKey)
	require.NoError(t, err)
	protected, err := store.VersionProtected(ctx, keeper)
	require.NoError(t, err)
	require.False(t, protected)
	require.NoError(t, store.ProtectVersion(ctx, keeper))
	protected, err = store.VersionProtected(ctx, keeper)
	require.NoError(t, err)
	require.True(t, protected)
	exists, err := store.VersionExists(ctx, original)
	require.NoError(t, err)
	require.True(t, exists)
	mu.Lock()
	objects[key]["new-v2"] = &object{body: "two"}
	latest[key] = "new-v2"
	mu.Unlock()
	require.NoError(t, store.DeleteVersion(ctx, original))
	exists, err = store.VersionExists(ctx, original)
	require.NoError(t, err)
	require.False(t, exists)
	current, err := store.CurrentVersion(ctx, key)
	require.NoError(t, err)
	require.Equal(t, "new-v2", current.VersionID)
	read, err = store.ReadVersion(ctx, current)
	require.NoError(t, err)
	raw, err = io.ReadAll(read)
	require.NoError(t, err)
	require.NoError(t, read.Close())
	require.Equal(t, "two", string(raw))
	require.Error(t, store.DeleteVersion(ctx, keeper))
	mu.Lock()
	defer mu.Unlock()
	require.Equal(t, 2, deletes)
	require.Equal(t, 1, holds)
	require.True(t, objects[keeperKey][keeper.VersionID].hold)
	require.Equal(t, "two", objects[key]["new-v2"].body)
}

/** 元数据或原版本响应不符时拒绝交付，非法版本及取消不应到达对象端。 */
func TestMetonS3BackupVersions_InvalidOrChangedVersion(t *testing.T) {
	v := service.BackupObjectVersion{Key: "backup/a.gz", VersionID: "v1", Size: 3}
	for _, item := range []struct {
		name, version, length, marker string
		currentOK                     bool
	}{
		{"missing", "", "3", "", false}, {"null", "null", "3", "", false},
		{"delete-marker", "v1", "3", "true", false}, {"empty", "v1", "0", "", false},
		{"different-version", "v2", "3", "", true}, {"different-size", "v1", "4", "", true},
	} {
		t.Run(item.name, func(t *testing.T) {
			store := backupVersionHTTPStore(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("X-Amz-Version-Id", item.version)
				if item.marker != "" {
					w.Header().Set("X-Amz-Delete-Marker", item.marker)
				}
				w.Header().Set("Content-Length", item.length)
				if r.Method != http.MethodHead {
					io.WriteString(w, "one")
				}
			})
			_, err := store.CurrentVersion(context.Background(), v.Key)
			if item.currentOK {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
			}
			body, err := store.ReadVersion(context.Background(), v)
			require.Error(t, err)
			require.Nil(t, body)
		})
	}
	var calls atomic.Int32
	store := backupVersionHTTPStore(t, func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(500) })
	for _, bad := range []service.BackupObjectVersion{{}, {Key: v.Key, VersionID: "null", Size: 3},
		{Key: v.Key, VersionID: "v1\n", Size: 3}, {Key: v.Key, VersionID: "v1", Size: 0}} {
		_, err := store.ReadVersion(context.Background(), bad)
		require.Error(t, err)
		_, err = store.VersionExists(context.Background(), bad)
		require.Error(t, err)
		require.Error(t, store.ProtectVersion(context.Background(), bad))
		_, err = store.VersionProtected(context.Background(), bad)
		require.Error(t, err)
		require.Error(t, store.DeleteVersion(context.Background(), bad))
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := store.CurrentVersion(ctx, v.Key)
	require.Error(t, err)
	_, err = store.ReadVersion(ctx, v)
	require.Error(t, err)
	_, err = store.VersionExists(ctx, v)
	require.Error(t, err)
	require.Error(t, store.ProtectVersion(ctx, v))
	_, err = store.VersionProtected(ctx, v)
	require.Error(t, err)
	require.Error(t, store.DeleteVersion(ctx, v))
	require.Zero(t, calls.Load())
}

/** 通用错误和不一致的范围响应保持未知，不误报原版本已经消失。 */
func TestMetonS3BackupVersions_PresenceRequiresOriginalEvidence(t *testing.T) {
	for _, item := range []struct {
		name, code, version, contentRange, marker, body string
		status                                          int
		absent                                          bool
	}{
		{name: "original-missing", code: "NoSuchVersion", status: 404, absent: true},
		{name: "generic-404", code: "NotFound", status: 404},
		{name: "missing-key", code: "NoSuchKey", status: 404},
		{name: "missing-bucket", code: "NoSuchBucket", status: 404},
		{name: "denied", code: "AccessDenied", status: 403},
		{name: "inconsistent-status", code: "NoSuchVersion", status: 500},
		{name: "unavailable", code: "ServiceUnavailable", status: 503},
		{name: "changed-version", version: "new-v2", contentRange: "bytes 0-0/3", body: "o", status: 206},
		{name: "changed-size", version: "v1", contentRange: "bytes 0-0/4", body: "o", status: 206},
		{name: "ignored-range", version: "v1", body: "o", status: 200},
		{name: "delete-marker", version: "v1", contentRange: "bytes 0-0/3", marker: "true", body: "o", status: 206},
		{name: "truncated-byte", version: "v1", contentRange: "bytes 0-0/3", status: 206},
	} {
		t.Run(item.name, func(t *testing.T) {
			var calls atomic.Int32
			store := backupVersionHTTPStore(t, func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Method != http.MethodGet || r.URL.Query().Get("versionId") != "v1" || r.Header.Get("Range") != "bytes=0-0" {
					t.Errorf("存在性查询没有绑定原版本和有界读取")
					w.WriteHeader(400)
					return
				}
				if item.code != "" {
					backupVersionHTTPError(w, item.status, item.code)
					return
				}
				w.Header().Set("X-Amz-Version-Id", item.version)
				if item.marker != "" {
					w.Header().Set("X-Amz-Delete-Marker", item.marker)
				}
				w.Header().Set("Content-Range", item.contentRange)
				w.Header().Set("Content-Length", "1")
				w.WriteHeader(item.status)
				io.WriteString(w, item.body)
			})
			exists, err := store.VersionExists(context.Background(), service.BackupObjectVersion{Key: "backup/a.gz", VersionID: "v1", Size: 3})
			require.False(t, exists)
			if item.absent {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
			}
			require.EqualValues(t, 1, calls.Load())
		})
	}
}

/** PUT 成功不代替另查 ON；对象锁不支持或回应无法识别时没有删除降级。 */
func TestMetonS3BackupVersions_HoldRequiresConfirmation(t *testing.T) {
	v := service.BackupObjectVersion{Key: "backup/keeper.gz", VersionID: "keep-v1", Size: 3}
	for _, item := range []struct {
		name, reply           string
		putStatus             int
		protected, queryError bool
	}{
		{"confirmed", "<LegalHold><Status>ON</Status></LegalHold>", 200, true, false},
		{"not-applied", "<LegalHold><Status>OFF</Status></LegalHold>", 200, false, false},
		{"missing", "<LegalHold/>", 200, false, true},
		{"unknown-state", "<LegalHold><Status>other</Status></LegalHold>", 200, false, true},
		{"unsupported", "", 501, false, true},
	} {
		t.Run(item.name, func(t *testing.T) {
			var calls atomic.Int32
			store := backupVersionHTTPStore(t, func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if !r.URL.Query().Has("legal-hold") || r.URL.Query().Get("versionId") != v.VersionID {
					t.Errorf("保护没有绑定保留版本")
					w.WriteHeader(400)
					return
				}
				if r.Method == http.MethodPut {
					var hold struct {
						Status string `xml:"Status"`
					}
					if xml.NewDecoder(r.Body).Decode(&hold) != nil || hold.Status != "ON" {
						t.Error("保护参数不是 ON")
					}
					if item.putStatus != 200 {
						backupVersionHTTPError(w, item.putStatus, "NotImplemented")
						return
					}
					w.WriteHeader(200)
					return
				}
				if r.Method != http.MethodGet {
					t.Errorf("非预期保护方法：%s", r.Method)
					w.WriteHeader(400)
					return
				}
				io.WriteString(w, item.reply)
			})
			err := store.ProtectVersion(context.Background(), v)
			if item.putStatus != 200 {
				require.Error(t, err)
				require.EqualValues(t, 1, calls.Load())
				return
			}
			require.NoError(t, err)
			protected, err := store.VersionProtected(context.Background(), v)
			require.Equal(t, item.protected, protected)
			if item.queryError {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
			require.EqualValues(t, 2, calls.Load())
		})
	}
}

/** 已执行但应答丢失、服务错误及错误回执都只发送一次，之后只能查询原版本。 */
func TestMetonS3BackupVersions_DeleteUnknownNeverRetries(t *testing.T) {
	v := service.BackupObjectVersion{Key: "backup/a.gz", VersionID: "old-v1", Size: 3}
	for _, mode := range []string{"disconnect", "unavailable", "missing-receipt", "wrong-version", "delete-marker", "redirect-307", "redirect-308"} {
		t.Run(mode, func(t *testing.T) {
			var deletes, reads atomic.Int32
			store := backupVersionHTTPStore(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Get("versionId") != v.VersionID || r.Header.Get("X-Amz-Bypass-Governance-Retention") != "" {
					t.Error("删除或核对没有绑定原版本")
					w.WriteHeader(400)
					return
				}
				if r.Method == http.MethodGet {
					reads.Add(1)
					backupVersionHTTPError(w, 404, "NoSuchVersion")
					return
				}
				if r.Method != http.MethodDelete {
					t.Errorf("非预期方法：%s", r.Method)
					w.WriteHeader(400)
					return
				}
				deletes.Add(1)
				switch mode {
				case "disconnect":
					connection, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Errorf("夹具断流失败：%v", err)
						return
					}
					connection.Close()
					return
				case "unavailable":
					backupVersionHTTPError(w, 503, "ServiceUnavailable")
					return
				case "redirect-307", "redirect-308":
					// 有意去掉原版本参数；客户端不能向这个新地址再发删除请求。
					w.Header().Set("Location", "/retirement-test/backup/a.gz")
					status := 307
					if mode == "redirect-308" {
						status = 308
					}
					w.WriteHeader(status)
					return
				case "wrong-version":
					w.Header().Set("X-Amz-Version-Id", "new-v2")
				case "delete-marker":
					w.Header().Set("X-Amz-Version-Id", v.VersionID)
					w.Header().Set("X-Amz-Delete-Marker", "true")
				}
				w.WriteHeader(204)
			})
			require.Error(t, store.DeleteVersion(context.Background(), v))
			require.EqualValues(t, 1, deletes.Load())
			exists, err := store.VersionExists(context.Background(), v)
			require.NoError(t, err)
			require.False(t, exists)
			require.EqualValues(t, 1, deletes.Load())
			require.EqualValues(t, 1, reads.Load())
		})
	}
}
