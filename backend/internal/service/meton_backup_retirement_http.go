package service

const BackupRetirementRoute = "/meton/backup-retirement/"

/** 备份服务身份与所有已配置的账号、模型及现金身份分离；人员执行资格仍须另问当前权威。 */
func (s MetonManagedSource) BackupRetirementKeyID() (string, bool) {
	return independentCashReadKey("METON_MANAGED_BACKUP_RETIREMENT_KEY_ID")
}

/** 普通构建的原解码器拒绝托管输入；不以宽松 JSON 解析扩大兼容范围。 */
func ReadBackupRetirementPlan(raw []byte, p *BackupRetirementPlan) error {
	return decodeStatement(raw, p)
}
