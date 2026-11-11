//go:build unit && meton_managed

package service

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

type retirementStore struct {
	*mockObjectStore
	versions              map[string][]byte
	current               map[string]string
	holds                 map[string]bool
	deletes               []BackupObjectVersion
	lostAfter, failBefore int
	protectFails          bool
}

func versionKey(v BackupObjectVersion) string { return v.Key + "\n" + v.VersionID }
func (s *retirementStore) put(key, version string, data []byte) {
	s.current[key] = version
	s.versions[key+"\n"+version] = append([]byte(nil), data...)
}
func (s *retirementStore) CurrentVersion(_ context.Context, key string) (BackupObjectVersion, error) {
	v := BackupObjectVersion{Key: key, VersionID: s.current[key]}
	v.Size = int64(len(s.versions[versionKey(v)]))
	return v, nil
}
func (s *retirementStore) ReadVersion(_ context.Context, v BackupObjectVersion) (io.ReadCloser, error) {
	data, ok := s.versions[versionKey(v)]
	if !ok {
		return nil, io.EOF
	}
	return io.NopCloser(bytes.NewReader(data)), nil
}
func (s *retirementStore) VersionExists(_ context.Context, v BackupObjectVersion) (bool, error) {
	_, ok := s.versions[versionKey(v)]
	return ok, nil
}
func (s *retirementStore) ProtectVersion(_ context.Context, v BackupObjectVersion) error {
	if s.protectFails {
		return io.ErrUnexpectedEOF
	}
	s.holds[versionKey(v)] = true
	return nil
}
func (s *retirementStore) VersionProtected(_ context.Context, v BackupObjectVersion) (bool, error) {
	return s.holds[versionKey(v)], nil
}
func (s *retirementStore) DeleteVersion(_ context.Context, v BackupObjectVersion) error {
	s.deletes = append(s.deletes, v)
	if s.failBefore == len(s.deletes) {
		return io.ErrUnexpectedEOF
	}
	if s.holds[versionKey(v)] {
		return errors.New("version is protected")
	}
	delete(s.versions, versionKey(v))
	if s.lostAfter == len(s.deletes) {
		return io.ErrUnexpectedEOF
	}
	return nil
}

type retirementAuthority struct {
	person    BackupRetentionOperator
	digests   map[string]string
	withdraw  bool
	onCurrent func(BackupRetentionIntent)
}

func (a *retirementAuthority) Current(_ context.Context, proof string, intent BackupRetentionIntent) (BackupRetentionOperator, error) {
	if a.onCurrent != nil {
		a.onCurrent(intent)
	}
	if a.withdraw || intent.Purpose != "cash.backup.retirement."+proof+".v1" ||
		(a.digests[proof] != "" && a.digests[proof] != intent.Digest) {
		return BackupRetentionOperator{}, ErrBackupRetirementUnavailable
	}
	return a.person, nil
}

type retirementRepo struct {
	*mockSettingRepo
	failState string
	after     bool
}

/** 与原 Settings 仓储同形；缺行不是一条内容为空的成功记录。 */
func (r *retirementRepo) GetValue(ctx context.Context, key string) (string, error) {
	r.mockSettingRepo.mu.Lock()
	_, exists := r.mockSettingRepo.data[key]
	r.mockSettingRepo.mu.Unlock()
	if !exists && strings.HasPrefix(key, backupRetirementPrefix) {
		return "", ErrSettingNotFound
	}
	return r.mockSettingRepo.GetValue(ctx, key)
}

func (r *retirementRepo) SetMultiple(ctx context.Context, values map[string]string) error {
	fail := false
	for key, value := range values {
		if strings.HasPrefix(key, backupRetirementPrefix) && r.failState != "" && strings.Contains(value, `"state":"`+r.failState+`"`) {
			fail = true
		}
	}
	if fail && !r.after {
		r.failState = ""
		return io.ErrUnexpectedEOF
	}
	err := r.mockSettingRepo.SetMultiple(ctx, values)
	if fail {
		r.failState = ""
		return io.ErrUnexpectedEOF
	}
	return err
}

func retirementFixture(t *testing.T, split bool) (*ManagedBackupRetirement, *retirementStore, *retirementAuthority, *retirementRepo, BackupRetirementPlan) {
	t.Helper()
	ctx := context.Background()
	repo := &retirementRepo{mockSettingRepo: newMockSettingRepo()}
	seedS3Config(t, repo.mockSettingRepo)
	store := &retirementStore{mockObjectStore: newMockObjectStore(), versions: map[string][]byte{}, current: map[string]string{}, holds: map[string]bool{}}
	store.put("target", "old", []byte("original"))
	store.put("keeper", "keep", []byte("original"))
	records := []BackupRecord{{ID: "target", Status: "completed", SizeBytes: 8, S3Key: "target", StartedAt: "2000-01-01T00:00:00Z"},
		{ID: "keeper", Status: "completed", SizeBytes: 8, S3Key: "keeper", StartedAt: "2000-01-01T00:00:00Z"},
		{ID: "other", Status: "completed", SizeBytes: 1, S3Key: "other"}}
	if split {
		delete(store.versions, "target\nold")
		delete(store.current, "target")
		store.put("target-a", "old-a", []byte("orig"))
		store.put("target-b", "old-b", []byte("inal"))
		records[0].S3Key = ""
		records[0].Parts = []BackupPart{{Index: 1, S3Key: "target-a", SizeBytes: 4}, {Index: 2, S3Key: "target-b", SizeBytes: 4}}
	}
	svc := newTestBackupService(repo.mockSettingRepo, &mockDumper{}, store.mockObjectStore)
	t.Cleanup(svc.Stop)
	svc.settingRepo = repo
	svc.storeFactory = func(context.Context, *BackupS3Config) (BackupObjectStore, error) { return store, nil }
	require.NoError(t, svc.saveRecordsLocked(ctx, records))
	authority := &retirementAuthority{person: BackupRetentionOperator{"fixture", "source", uuid.NewString(), 1, 1, time.Now().Add(time.Hour)}, digests: map[string]string{}}
	r := &ManagedBackupRetirement{Backups: svc, Authority: authority, Environment: "fixture", Source: "source", MaxBytes: 1024}
	p, err := r.Inspect(ctx, "inspect", uuid.NewString(), "target", "keeper")
	require.NoError(t, err)
	for _, action := range []string{"execute", "reconcile", "resume"} {
		authority.digests[action] = p.Digest()
	}
	return r, store, authority, repo, p
}

/** 正向退役完整同内容副本，原回执、保留副本保护及其他记录均持续存在。 */
func TestManagedBackupRetirement_ExactReplicaAndDurablePins(t *testing.T) {
	r, s, _, _, p := retirementFixture(t, false)
	ctx := context.Background()
	originalKeeper, err := r.Backups.GetBackupRecord(ctx, "keeper")
	require.NoError(t, err)
	result, err := r.Execute(ctx, "execute", p)
	require.NoError(t, err)
	require.Equal(t, "completed", result.State)
	require.Len(t, s.deletes, 1)
	require.Empty(t, s.deletedKeys)
	require.Equal(t, p.TargetObjects[0], s.deletes[0])
	require.True(t, s.holds[versionKey(p.KeeperObjects[0])])
	require.Equal(t, []byte("original"), s.versions["keeper\nkeep"])
	for range 2 {
		again, err := r.Execute(ctx, "execute", p)
		require.NoError(t, err)
		require.Equal(t, result, again)
	}
	require.Len(t, s.deletes, 1)
	require.NoError(t, r.Backups.saveRecord(ctx, originalKeeper))
	changedKeeper := *originalKeeper
	changedKeeper.S3Key = "replacement"
	require.Error(t, r.Backups.saveRecord(ctx, &changedKeeper))
	changedKeeper = *originalKeeper
	changedKeeper.Status = "running"
	require.Error(t, r.Backups.saveRecord(ctx, &changedKeeper))
	keeper, err := r.Backups.GetBackupRecord(ctx, "keeper")
	require.NoError(t, err)
	require.True(t, keeper.MetonRetentionPinned)
	target, err := r.Backups.GetBackupRecord(ctx, "target")
	require.NoError(t, err)
	require.Equal(t, "retired", target.Status)
	target.Status = "completed"
	require.Error(t, r.Backups.saveRecord(ctx, target))
	other, err := r.Backups.GetBackupRecord(ctx, "other")
	require.NoError(t, err)
	require.Equal(t, "completed", other.Status)
	_, err = r.Inspect(ctx, "inspect", uuid.NewString(), "keeper", "other")
	require.Error(t, err)
}

/** 删除后丢应答只查原版本；同名新版本和其他账号／备份记录不会随重试删除。 */
func TestManagedBackupRetirement_UnknownOnlyQueriesOriginalVersions(t *testing.T) {
	r, s, a, _, p := retirementFixture(t, false)
	ctx := context.Background()
	s.lostAfter = 1
	result, err := r.Execute(ctx, "execute", p)
	require.Error(t, err)
	require.Equal(t, "unknown", result.State)
	s.put("target", "new", []byte("new owner bytes"))
	result, err = r.Execute(ctx, "execute", p)
	require.NoError(t, err)
	require.Equal(t, "completed", result.State)
	require.Len(t, s.deletes, 1)
	require.Equal(t, []byte("new owner bytes"), s.versions["target\nnew"])
	a.person.Generation = 2
	_, err = r.Execute(ctx, "execute", p)
	require.Error(t, err)
	result, err = r.Reconcile(ctx, "reconcile", p)
	require.NoError(t, err)
	require.Equal(t, "completed", result.State)
}

/** 部分删除需当前人员明确续作；续作仍只操作原固定版本，并重新读取保留内容。 */
func TestManagedBackupRetirement_PartialNeedsExplicitResume(t *testing.T) {
	r, s, a, _, p := retirementFixture(t, true)
	ctx := context.Background()
	s.failBefore = 2
	result, err := r.Execute(ctx, "execute", p)
	require.Error(t, err)
	require.Equal(t, "unknown", result.State)
	s.put("target-a", "new-a", []byte("new data"))
	result, err = r.Execute(ctx, "execute", p)
	require.NoError(t, err)
	require.Equal(t, "unknown", result.State)
	require.Len(t, s.deletes, 2)
	_, err = r.Inspect(ctx, "inspect", uuid.NewString(), "target", "keeper")
	require.Error(t, err)
	_, err = r.Resume(ctx, "execute", p)
	require.Error(t, err)
	require.Len(t, s.deletes, 2)
	s.failBefore = 0
	result, err = r.Resume(ctx, "resume", p)
	require.NoError(t, err)
	require.Equal(t, "completed", result.State)
	require.Len(t, s.deletes, 3)
	require.Equal(t, p.TargetObjects[1], s.deletes[2])
	require.Equal(t, []byte("new data"), s.versions["target-a\nnew-a"])
	a.person.Generation = 2
	_, err = r.Resume(ctx, "resume", p)
	require.Error(t, err)
	require.Len(t, s.deletes, 3)
	r2, s2, a2, _, p2 := retirementFixture(t, false)
	s2.failBefore = 1
	_, err = r2.Execute(ctx, "execute", p2)
	require.Error(t, err)
	a2.person.Generation = 2
	_, err = r2.Resume(ctx, "resume", p2)
	require.Error(t, err)
	result, err = r2.Reconcile(ctx, "reconcile", p2)
	require.NoError(t, err)
	require.Equal(t, "unknown", result.State)
	require.Len(t, s2.deletes, 1)
}

/** 保存计划、派发标记或最终回执丢失时不猜测成功，不以新操作重做删除。 */
func TestManagedBackupRetirement_PersistenceUnknownAndChangedAuthority(t *testing.T) {
	for _, state := range []string{"prepared", "attempted", "completed"} {
		t.Run(state, func(t *testing.T) {
			r, s, _, repo, p := retirementFixture(t, false)
			ctx := context.Background()
			repo.failState = state
			repo.after = true
			result, err := r.Execute(ctx, "execute", p)
			require.Error(t, err)
			require.Equal(t, "unknown", result.State)
			result, err = r.Execute(ctx, "execute", p)
			require.NoError(t, err)
			if state == "attempted" {
				require.Equal(t, "unknown", result.State)
				require.Empty(t, s.deletes)
				result, err = r.Resume(ctx, "resume", p)
				require.NoError(t, err)
			}
			require.Equal(t, "completed", result.State)
			require.Len(t, s.deletes, 1)
		})
	}
	r, s, a, _, p := retirementFixture(t, false)
	calls := 0
	a.onCurrent = func(intent BackupRetentionIntent) {
		if strings.Contains(intent.Purpose, "execute") {
			calls++
			if calls == 2 {
				a.withdraw = true
			}
		}
	}
	_, err := r.Execute(context.Background(), "execute", p)
	require.Error(t, err)
	require.Empty(t, s.deletes)
}

/** 内容变化、用途错误、缺保护或共享键均不能把备份数量当作可删除证明。 */
func TestManagedBackupRetirement_RejectsIncompleteOrChangedCoverage(t *testing.T) {
	r, s, _, _, _ := retirementFixture(t, false)
	_, err := r.Inspect(context.Background(), "inspect", uuid.Nil.String(), "target", "keeper")
	require.Error(t, err)
	require.Empty(t, s.deletes)
	for _, kind := range []string{"content", "version", "shared", "monthly", "missing-hold", "wrong-purpose", "plan", "no-authority", "invalid-version", "bytes"} {
		t.Run(kind, func(t *testing.T) {
			r, s, _, _, p := retirementFixture(t, false)
			ctx := context.Background()
			proof := "execute"
			switch kind {
			case "content":
				s.put("keeper", "changed", []byte("different"))
			case "version":
				s.put("keeper", "changed", []byte("original"))
			case "shared":
				records, err := r.Backups.loadRecordsLocked(ctx)
				require.NoError(t, err)
				records[2].S3Key = "target"
				require.NoError(t, r.Backups.saveRecordsLocked(ctx, records))
			case "monthly":
				target, err := r.Backups.GetBackupRecord(ctx, "target")
				require.NoError(t, err)
				target.MonthlyArchive = &BackupMonthlyArchive{}
				require.NoError(t, r.Backups.saveRecord(ctx, target))
			case "missing-hold":
				s.protectFails = true
			case "wrong-purpose":
				proof = "inspect"
			case "plan":
				p.Content = strings.Repeat("0", 64)
			case "no-authority":
				r.Authority = nil
			case "invalid-version":
				p.TargetObjects[0].VersionID = "null"
			case "bytes":
				p.Bytes = 1 << 40
			}
			_, err := r.Execute(ctx, proof, p)
			require.Error(t, err)
			require.Empty(t, s.deletes)
			require.NotEmpty(t, s.versions["target\nold"])
		})
	}
}
