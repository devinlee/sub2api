//go:build unit && meton_managed

package service

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

/** 外部配置更新不能给缓存旧客户端贴新摘要；原计划位置途中变化应在对象副作用前拒绝。 */
func TestManagedBackupRetirement_CurrentLocationNeverUsesOldCache(t *testing.T) {
	r, store, authority, repo, _ := retirementFixture(t, false)
	ctx := context.Background()
	original, err := r.Backups.loadS3Config(ctx)
	require.NoError(t, err)
	_, err = r.Backups.getOrCreateStore(ctx, original)
	require.NoError(t, err)
	changed := *original
	changed.Bucket = "new-isolated-bucket"
	raw, err := json.Marshal(changed)
	require.NoError(t, err)
	require.NoError(t, repo.Set(ctx, settingKeyBackupS3Config, string(raw)))
	seen := ""
	r.Backups.storeFactory = func(_ context.Context, cfg *BackupS3Config) (BackupObjectStore, error) {
		seen = cfg.Bucket
		return store, nil
	}
	plan, err := r.Inspect(ctx, "inspect", uuid.NewString(), "target", "keeper")
	require.NoError(t, err)
	require.Equal(t, changed.Bucket, seen)
	require.Equal(t, backupRetentionLocation(&changed), plan.Location)
	authority.digests["execute"] = plan.Digest()
	authority.onCurrent = func(intent BackupRetentionIntent) {
		if intent.Purpose == "cash.backup.retirement.execute.v1" {
			changed.Bucket = "another-isolated-bucket"
			value, _ := json.Marshal(changed)
			require.NoError(t, repo.Set(ctx, settingKeyBackupS3Config, string(value)))
		}
	}
	_, err = r.Execute(ctx, "execute", plan)
	require.Error(t, err)
	require.Empty(t, store.deletes)
	require.Empty(t, store.holds)
}
