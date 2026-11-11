//go:build unit && meton_managed

package service

import (
	"context"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

type retirementLookupRepo struct {
	SettingRepository
	fail error
}

/** 仅原操作查询注入缺行、空行或故障，其他配置和记录仍经原测试仓储。 */
func (r retirementLookupRepo) GetValue(ctx context.Context, key string) (string, error) {
	if strings.HasPrefix(key, backupRetirementPrefix) {
		return "", r.fail
	}
	return r.SettingRepository.GetValue(ctx, key)
}

/** 首次操作识别原仓储 NotFound；读取未知和空记录不得触发保护或删除。 */
func TestManagedBackupRetirement_OriginalMissingSettingAndLookupFailure(t *testing.T) {
	ctx := context.Background()
	r, store, _, repo, plan := retirementFixture(t, false)
	_, exists, err := r.operation(ctx, plan.Operation)
	require.NoError(t, err)
	require.False(t, exists)
	result, err := r.Execute(ctx, "execute", plan)
	require.NoError(t, err)
	require.Equal(t, "completed", result.State)
	require.Len(t, store.deletes, 1)
	_, exists, err = r.operation(ctx, plan.Operation)
	require.NoError(t, err)
	require.True(t, exists)
	r.Backups.settingRepo = retirementLookupRepo{repo, fmt.Errorf("wrapped: %w", ErrSettingNotFound)}
	_, exists, err = r.operation(ctx, plan.Operation)
	require.NoError(t, err)
	require.False(t, exists)
	for _, fault := range []struct {
		name string
		err  error
	}{{"empty_existing", nil}, {"query_unknown", io.ErrUnexpectedEOF}, {"cancelled", context.Canceled}} {
		t.Run(fault.name, func(t *testing.T) {
			r, store, _, repo, plan := retirementFixture(t, false)
			r.Backups.settingRepo = retirementLookupRepo{repo, fault.err}
			_, err := r.Execute(ctx, "execute", plan)
			require.Error(t, err)
			require.Empty(t, store.deletes)
			require.Empty(t, store.holds)
			repo.mu.Lock()
			_, saved := repo.data[backupRetirementPrefix+plan.Operation]
			repo.mu.Unlock()
			require.False(t, saved)
		})
	}
}
