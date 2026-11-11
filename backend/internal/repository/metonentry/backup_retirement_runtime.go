//go:build meton_managed

package metonentry

import (
	"context"
	"path/filepath"
	"sync/atomic"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

type backupRetirementRuntimeConfiguration struct {
	FormatVersion int                     `json:"format_version"`
	Environment   string                  `json:"environment"`
	Source        string                  `json:"source"`
	SourceEpoch   int64                   `json:"source_epoch"`
	KeyID         string                  `json:"key_id"`
	MaxBytes      int64                   `json:"max_bytes"`
	Authority     backupAuthorityMaterial `json:"authority"`
}

type backupRetirementRuntimeAuthority struct {
	authority      service.BackupRetentionAuthority
	file           backupAuthorityFile
	source         service.MetonManagedSource
	key            string
	closeAuthority func()
	closed         atomic.Bool
}

/** 当前部署和当前人员是两项复验；来源装配改变后不沿旧连接继续原任务。 */
func (a *backupRetirementRuntimeAuthority) current() bool {
	live, ok := service.MetonSource()
	key, enabled := live.BackupRetirementKeyID()
	current, _, err := readBackupAuthorityFile(a.file.path, a.file.limit)
	if a.closed.Load() || !ok || !enabled || live != a.source || key != a.key || err != nil || current.hash != a.file.hash || !a.file.same(current) {
		a.close()
		return false
	}
	return true
}

/** 包含人员原有效期的结果只沿同一配置交还，旧部署不能因文件换回而复活。 */
func (a *backupRetirementRuntimeAuthority) Current(ctx context.Context, assertion string, intent service.BackupRetentionIntent) (service.BackupRetentionOperator, error) {
	if !a.current() {
		return service.BackupRetentionOperator{}, service.ErrBackupRetirementUnavailable
	}
	person, err := a.authority.Current(ctx, assertion, intent)
	if err != nil || ctx.Err() != nil || !a.current() {
		return service.BackupRetentionOperator{}, service.ErrBackupRetirementUnavailable
	}
	return person, nil
}

/** 退出仅退役本代来源客户端，不能清除备份记录、对象或其他来源的资源。 */
func (a *backupRetirementRuntimeAuthority) close() {
	if a.closed.CompareAndSwap(false, true) {
		a.closeAuthority()
	}
}

/** 与原 Host 一起装配，BackupService 由原处理器注入，不在此重建仓储或备份服务。 */
func OpenBackupRetirement(path string) (*service.ManagedBackupRetirement, func(), error) {
	noop := func() {}
	if path == "" {
		return nil, noop, nil
	}
	file, raw, err := readBackupAuthorityFile(path, 16384)
	var cfg backupRetirementRuntimeConfiguration
	source, ok := service.MetonSource()
	key, enabled := source.BackupRetirementKeyID()
	if err != nil || !ok || !enabled || metonexecution.DecodeStrict(raw, &cfg) != nil || cfg.FormatVersion != 1 ||
		cfg.Environment != source.Environment || cfg.Source != source.Source || cfg.SourceEpoch != source.Epoch || cfg.KeyID != key ||
		cfg.MaxBytes <= 0 || cfg.MaxBytes > 1<<40 || !backupAuthorityHash(cfg.Authority.SHA256) {
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	name := cfg.Authority.Path
	if !filepath.IsAbs(name) {
		name = filepath.Join(filepath.Dir(path), name)
	}
	authorityFile, _, err := readBackupAuthorityFile(name, 16384)
	if err != nil || authorityFile.hash != cfg.Authority.SHA256 {
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	authority, closeAuthority, err := OpenBackupRetentionAuthority(name, source.Environment, source.Source)
	if err != nil || authority == nil {
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	// 装配过程也不能被换入另一份有效但不在固定摘要中的权威配置。
	final, _, err := readBackupAuthorityFile(name, 16384)
	if err != nil || final.hash != authorityFile.hash || !authorityFile.same(final) {
		closeAuthority()
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	guarded := &backupRetirementRuntimeAuthority{authority: authority, file: file, source: source, key: key, closeAuthority: closeAuthority}
	if !guarded.current() {
		guarded.close()
		return nil, noop, service.ErrBackupRetirementUnavailable
	}
	return &service.ManagedBackupRetirement{Authority: guarded, Environment: source.Environment, Source: source.Source, MaxBytes: cfg.MaxBytes}, guarded.close, nil
}
