package service

import infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"

var (
	ErrMetonBackupRetentionRequired = infraerrors.Forbidden("METON_BACKUP_RETENTION_REQUIRED", "managed backup objects must be retained for controlled reconciliation")
	ErrMetonBackupRecoveryRequired  = infraerrors.Forbidden("METON_BACKUP_RECOVERY_REQUIRED", "managed backup restore requires the external recovery barrier")
)

/** 原生备份状态和年龄不证明资金材料已经失去引用，托管对象不得由该入口清理。 */
func checkNativeBackupRemoval() error {
	if MetonManagedBuild {
		return ErrMetonBackupRetentionRequired
	}
	return nil
}

/** 原生单库恢复没有 Meton 当前屏障，不能借旧快照恢复凭据或资金执行资格。 */
func checkNativeBackupRestore() error {
	if MetonManagedBuild {
		return ErrMetonBackupRecoveryRequired
	}
	return nil
}
