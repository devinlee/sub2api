//go:build unit && meton_managed

package service

import (
	"context"
	"fmt"
	"io"
	"slices"
	"testing"

	"github.com/stretchr/testify/require"
)

/** 在对象已保存之后丢弃上传应答，不能把错误当成对象不存在。 */
type metonBackupObservedStore struct {
	*mockObjectStore
	loseUploadAt int
	downloads    int
}

/** 原上传先完成，随后只丢客户端应答，以覆盖不可删除的未知结果。 */
func (s *metonBackupObservedStore) UploadFile(ctx context.Context, key, path, contentType string) (int64, error) {
	n, err := s.mockObjectStore.UploadFile(ctx, key, path, contentType)
	if err == nil && s.uploadFileCalls == s.loseUploadAt {
		return 0, fmt.Errorf("injected response loss after object persisted")
	}
	return n, err
}

/** 记录实际读取，确保恢复拒绝发生在接触原对象之前。 */
func (s *metonBackupObservedStore) Download(ctx context.Context, key string) (io.ReadCloser, error) {
	s.downloads++
	return s.mockObjectStore.Download(ctx, key)
}

/** 年龄、份数、月度确认和重启都不得移除原对象或它的定位信息。 */
func TestMetonBackup_RetainsObjectsAcrossDeletionAndRestart(t *testing.T) {
	ctx := context.Background()
	repo, store := newMockSettingRepo(), newMockObjectStore()
	seedS3Config(t, repo)
	svc := newTestBackupService(repo, &mockDumper{}, store)
	defer svc.Stop()
	const old = "2000-01-01T00:00:00Z"
	records := []BackupRecord{
		{ID: "ordinary", Status: "completed", StartedAt: old, S3Key: "ordinary", ExpiresAt: old},
		{ID: "monthly", Status: "completed", StartedAt: old, S3Key: "monthly", MonthlyArchive: &BackupMonthlyArchive{RetainCount: 1}},
		{ID: "permanent", Status: "completed", StartedAt: old, S3Key: "permanent", MonthlyArchive: &BackupMonthlyArchive{}},
		{ID: "failed", Status: "failed", StartedAt: old, S3Key: "failed"},
		{ID: "interrupted", Status: "running", StartedAt: old, Parts: []BackupPart{{Index: 1, S3Key: "partial-1"}, {Index: 2, S3Key: "partial-2"}}},
		{ID: "other", Status: "completed", StartedAt: old, S3Key: "other"},
		{ID: "no-key", Status: "failed", StartedAt: old},
	}
	for _, record := range records {
		for _, key := range backupObjectKeys(&record) {
			store.objects[key] = []byte("retained original " + key)
		}
	}
	require.NoError(t, svc.saveRecordsLocked(ctx, records))
	original, err := repo.GetValue(ctx, settingKeyBackupRecords)
	require.NoError(t, err)
	for range 2 {
		for _, record := range records {
			require.ErrorIs(t, svc.DeleteBackup(ctx, record.ID), ErrMetonBackupRetentionRequired)
			require.ErrorIs(t, svc.DeleteArchivedBackup(ctx, record.ID), ErrMetonBackupRetentionRequired)
			require.ErrorIs(t, svc.deleteBackupObjects(ctx, &record), ErrMetonBackupRetentionRequired)
			require.ErrorIs(t, deleteBackupObjectKeys(ctx, store, &record), ErrMetonBackupRetentionRequired)
		}
		require.ErrorIs(t, svc.cleanupOldBackups(ctx, &BackupScheduleConfig{RetainDays: 1, RetainCount: 1}), ErrMetonBackupRetentionRequired)
	}
	unchanged, err := repo.GetValue(ctx, settingKeyBackupRecords)
	require.NoError(t, err)
	require.Equal(t, original, unchanged)
	svc.recoverStaleRecords()
	svc.recoverStaleRecords()
	retained, err := svc.ListBackups(ctx)
	require.NoError(t, err)
	require.Len(t, retained, len(records))
	for _, before := range records {
		after, err := svc.GetBackupRecord(ctx, before.ID)
		require.NoError(t, err)
		if before.ID == "interrupted" {
			require.Equal(t, "failed", after.Status)
			require.Contains(t, after.ErrorMsg, "retained for controlled reconciliation")
			require.Equal(t, before.Parts, after.Parts)
		} else {
			require.Equal(t, before, *after)
		}
		for _, key := range backupObjectKeys(&before) {
			require.Equal(t, []byte("retained original "+key), store.objects[key])
		}
	}
	require.Empty(t, store.deletedKeys)
}

/** 单文件及分卷上传已落对象但丢应答时，保留原计划供后续核对。 */
func TestMetonBackup_UploadUnknownRetainsObjectsAndMetadata(t *testing.T) {
	for _, split := range []bool{false, true} {
		t.Run(fmt.Sprint(split), func(t *testing.T) {
			ctx := context.Background()
			repo, objects := newMockSettingRepo(), newMockObjectStore()
			seedS3Config(t, repo)
			store := &metonBackupObservedStore{mockObjectStore: objects, loseUploadAt: 1}
			svc := newTestBackupService(repo, &mockDumper{dumpData: []byte("isolated original financial records")}, objects)
			defer svc.Stop()
			svc.storeFactory = func(context.Context, *BackupS3Config) (BackupObjectStore, error) { return store, nil }
			if split {
				svc.partSizeBytes = 8
				store.loseUploadAt = 2
			}
			record, err := svc.CreateBackup(ctx, "isolated-retention", 1)
			require.ErrorIs(t, err, ErrMetonBackupRetentionRequired)
			require.NotNil(t, record)
			require.Equal(t, "failed", record.Status)
			require.Contains(t, record.ErrorMsg, "response loss")
			stored, err := svc.GetBackupRecord(ctx, record.ID)
			require.NoError(t, err)
			require.Equal(t, *record, *stored)
			require.Len(t, objects.objects, store.loseUploadAt)
			keys := backupObjectKeys(stored)
			for key := range objects.objects {
				require.True(t, slices.Contains(keys, key))
			}
			svc.recoverStaleRecords()
			require.ErrorIs(t, svc.DeleteBackup(ctx, record.ID), ErrMetonBackupRetentionRequired)
			require.Len(t, objects.objects, store.loseUploadAt)
			require.Empty(t, objects.deletedKeys)
		})
	}
}

/** 原备份正向生成和读取继续可用，所有原地恢复入口均在副作用前拒绝。 */
func TestMetonBackup_ReadsBackupButRejectsNativeRestore(t *testing.T) {
	ctx := context.Background()
	repo, objects := newMockSettingRepo(), newMockObjectStore()
	seedS3Config(t, repo)
	store := &metonBackupObservedStore{mockObjectStore: objects}
	dumper := &mockDumper{dumpData: []byte("isolated retained snapshot")}
	svc := newTestBackupService(repo, dumper, objects)
	defer svc.Stop()
	svc.storeFactory = func(context.Context, *BackupS3Config) (BackupObjectStore, error) { return store, nil }
	record, err := svc.CreateBackup(ctx, "isolated-retention", 0)
	require.NoError(t, err)
	require.Equal(t, "completed", record.Status)
	_, err = svc.GetBackupDownloadURL(ctx, record.ID)
	require.NoError(t, err)
	for range 2 {
		require.ErrorIs(t, svc.RestoreBackup(ctx, record.ID), ErrMetonBackupRecoveryRequired)
		pending, err := svc.StartRestore(ctx, record.ID)
		require.ErrorIs(t, err, ErrMetonBackupRecoveryRequired)
		require.Nil(t, pending)
		pending, err = svc.beginBackupRestore(ctx, record.ID)
		require.ErrorIs(t, err, ErrMetonBackupRecoveryRequired)
		require.Nil(t, pending)
		require.ErrorIs(t, svc.restoreArchive(ctx, "must-not-open"), ErrMetonBackupRecoveryRequired)
	}
	record.RestoreStatus, record.RestoreStartedAt = "running", "2000-01-01T00:00:00Z"
	require.NoError(t, svc.saveRecord(ctx, record))
	svc.executeRestore(record, store)
	after, err := svc.GetBackupRecord(ctx, record.ID)
	require.NoError(t, err)
	require.Equal(t, "failed", after.RestoreStatus)
	require.Contains(t, after.RestoreError, "external recovery barrier")
	record.RestoreStatus = "completed"
	require.ErrorIs(t, svc.saveRestoreRecord(ctx, record), ErrMetonBackupRecoveryRequired)
	current, err := svc.GetBackupRecord(ctx, record.ID)
	require.NoError(t, err)
	require.Equal(t, *after, *current)
	require.Zero(t, store.downloads)
	require.Empty(t, dumper.restored)
	require.Empty(t, objects.deletedKeys)
	require.Len(t, objects.objects, 1)
}
