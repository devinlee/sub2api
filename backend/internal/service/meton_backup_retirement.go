package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/google/uuid"
)

const backupRetirementPrefix = "meton_backup_retirement_"

var ErrBackupRetirementUnavailable = errors.New("managed backup retirement is unavailable or requires reconciliation")

/** 固定版本必须由对象端提供，不能用文件名、ETag 或客户端自造编号代替。 */
type BackupObjectVersion struct {
	Key       string `json:"key"`
	VersionID string `json:"version_id"`
	Size      int64  `json:"size"`
}

/** 持久保护必须阻止自动清理和普通删除；不支持的存储不得降级到按名 Delete。 */
type RetainedBackupObjectStore interface {
	BackupObjectStore
	CurrentVersion(context.Context, string) (BackupObjectVersion, error)
	ReadVersion(context.Context, BackupObjectVersion) (io.ReadCloser, error)
	VersionExists(context.Context, BackupObjectVersion) (bool, error)
	ProtectVersion(context.Context, BackupObjectVersion) error
	VersionProtected(context.Context, BackupObjectVersion) (bool, error)
	DeleteVersion(context.Context, BackupObjectVersion) error
}

type BackupRetentionIntent struct {
	Purpose, Environment, Source, Operation, Target, Keeper, Digest string
}

type BackupRetentionOperator struct {
	Environment, Source, Person string
	Generation, Version         int64
	Until                       time.Time
}

/** 实现方必须查询还原范围外的当前权威并记录审计；读取用途不能批准执行或续作。 */
type BackupRetentionAuthority interface {
	Current(context.Context, string, BackupRetentionIntent) (BackupRetentionOperator, error)
}

type BackupRetirementPlan struct {
	Format        int                   `json:"format_version"`
	Operation     string                `json:"operation"`
	Environment   string                `json:"environment"`
	Source        string                `json:"source"`
	Generation    int64                 `json:"generation"`
	Target        string                `json:"target"`
	Keeper        string                `json:"keeper"`
	TargetRecord  string                `json:"target_record"`
	KeeperRecord  string                `json:"keeper_record"`
	Location      string                `json:"location"`
	Content       string                `json:"content"`
	Bytes         int64                 `json:"bytes"`
	TargetObjects []BackupObjectVersion `json:"target_objects"`
	KeeperObjects []BackupObjectVersion `json:"keeper_objects"`
}

type BackupRetirementReceipt struct {
	Operation  string `json:"operation"`
	State      string `json:"state"`
	PlanDigest string `json:"plan_digest"`
}

type backupRetirementOperation struct {
	Format       int                  `json:"format_version"`
	Plan         BackupRetirementPlan `json:"plan"`
	Digest       string               `json:"digest"`
	State        string               `json:"state"`
	Actor        string               `json:"actor"`
	ActorVersion int64                `json:"actor_version"`
}

/** 协调原备份记录和固定版本对象，不取得数据库恢复或原资金／密钥删除端口。 */
type ManagedBackupRetirement struct {
	Backups             *BackupService
	Authority           BackupRetentionAuthority
	Environment, Source string
	MaxBytes            int64
}

/** 摘要由固定结构计算；执行方重新计算，不信任调用方另给的摘要字符串。 */
func (p BackupRetirementPlan) Digest() string { return backupRetirementDigest(p) }

/** 原计划按同一结构固定，保留对象版本和完整内容身份。 */
func backupRetirementDigest(value any) string {
	raw, _ := json.Marshal(value)
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:])
}

/** 未装配当前权威或超出本部署比较预算时不开放协调。 */
func (r *ManagedBackupRetirement) valid(p BackupRetirementPlan) bool {
	id, err := uuid.Parse(p.Operation)
	return MetonManagedBuild && r.Backups != nil && r.Authority != nil && r.MaxBytes > 0 && r.MaxBytes <= 1<<40 &&
		r.Environment != "" && r.Source != "" && err == nil && id != uuid.Nil && id.String() == p.Operation &&
		p.Format == 1 && p.Environment == r.Environment && p.Source == r.Source && p.Target != "" &&
		p.Keeper != "" && p.Target != p.Keeper && len(p.Target) <= 128 && len(p.Keeper) <= 128
}

/** 完整计划先限界，再计算摘要和读取原操作；不让任意对象列表抵达删除端口。 */
func (r *ManagedBackupRetirement) fullPlan(p BackupRetirementPlan) bool {
	if !r.valid(p) || p.Generation <= 0 || p.Bytes <= 0 || p.Bytes > r.MaxBytes {
		return false
	}
	for _, hash := range []string{p.TargetRecord, p.KeeperRecord, p.Location, p.Content} {
		raw, err := hex.DecodeString(hash)
		if err != nil || len(raw) != 32 || hex.EncodeToString(raw) != hash {
			return false
		}
	}
	allKeys := map[string]bool{}
	for _, objects := range [][]BackupObjectVersion{p.TargetObjects, p.KeeperObjects} {
		if len(objects) == 0 || len(objects) > 1024 {
			return false
		}
		var size int64
		for _, v := range objects {
			if v.Key == "" || len(v.Key) > 1024 || v.VersionID == "" || v.VersionID == "null" || len(v.VersionID) > 1024 ||
				v.Size <= 0 || v.Size > r.MaxBytes-size || allKeys[v.Key] {
				return false
			}
			allKeys[v.Key] = true
			size += v.Size
		}
		if size != p.Bytes {
			return false
		}
	}
	raw, err := json.Marshal(p)
	return err == nil && len(raw) <= 768*1024
}

/** 每次重新询问外部当前资格；历史批准和操作记录不能代替它。 */
func (r *ManagedBackupRetirement) current(ctx context.Context, assertion, purpose string, p BackupRetirementPlan, digest string) (BackupRetentionOperator, error) {
	if !r.valid(p) || len(assertion) == 0 || len(assertion) > 8185 {
		return BackupRetentionOperator{}, ErrBackupRetirementUnavailable
	}
	person, err := r.Authority.Current(ctx, assertion, BackupRetentionIntent{purpose, r.Environment, r.Source, p.Operation, p.Target, p.Keeper, digest})
	if err != nil || ctx.Err() != nil || person.Environment != r.Environment || person.Source != r.Source ||
		person.Person == "" || person.Version <= 0 || person.Generation <= 0 || !person.Until.After(time.Now()) || !r.locationCurrent(ctx, p) {
		return BackupRetentionOperator{}, ErrBackupRetirementUnavailable
	}
	return person, nil
}

/** 只产生待核对计划；读取人员与执行人员用途不同，返回计划本身不授权删除。 */
func (r *ManagedBackupRetirement) Inspect(ctx context.Context, assertion, operation, target, keeper string) (BackupRetirementPlan, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	p := BackupRetirementPlan{Format: 1, Operation: operation, Environment: r.Environment, Source: r.Source, Target: target, Keeper: keeper}
	intent := p.Digest()
	person, err := r.current(ctx, assertion, "cash.backup.retirement.inspect.v1", p, intent)
	if err != nil {
		return BackupRetirementPlan{}, err
	}
	ctx, release, err := r.Backups.lockBackupRecordUpdates(ctx)
	if err != nil {
		return BackupRetirementPlan{}, err
	}
	defer release()
	p.Generation = person.Generation
	plan, _, _, err := r.planLocked(ctx, p)
	if err != nil {
		return BackupRetirementPlan{}, err
	}
	if !r.fullPlan(plan) {
		return BackupRetirementPlan{}, ErrBackupRetirementUnavailable
	}
	final, err := r.current(ctx, assertion, "cash.backup.retirement.inspect.v1", p, intent)
	if err != nil || final != person || !r.locationCurrent(ctx, plan) {
		return BackupRetirementPlan{}, ErrBackupRetirementUnavailable
	}
	return plan, nil
}

/** 重复执行已尝试的操作只核对原版本，不能自动再次删除。 */
func (r *ManagedBackupRetirement) Execute(ctx context.Context, assertion string, plan BackupRetirementPlan) (BackupRetirementReceipt, error) {
	return r.apply(ctx, assertion, plan, "execute")
}

/** 当前人员可只读核对旧代次原操作；不能由该用途开始或续作删除。 */
func (r *ManagedBackupRetirement) Reconcile(ctx context.Context, assertion string, plan BackupRetirementPlan) (BackupRetirementReceipt, error) {
	return r.apply(ctx, assertion, plan, "reconcile")
}

/** 明确续作仍使用同一操作及精确版本，需要独立当前用途并重新检查保留副本。 */
func (r *ManagedBackupRetirement) Resume(ctx context.Context, assertion string, plan BackupRetirementPlan) (BackupRetirementReceipt, error) {
	return r.apply(ctx, assertion, plan, "resume")
}

/** 原操作先持久取得目标，再保护副本和标记派发；未知结果不重新创建操作。 */
func (r *ManagedBackupRetirement) apply(ctx context.Context, assertion string, p BackupRetirementPlan, action string) (BackupRetirementReceipt, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	result := BackupRetirementReceipt{Operation: p.Operation, State: "retained"}
	if !r.fullPlan(p) {
		return result, ErrBackupRetirementUnavailable
	}
	result.PlanDigest = p.Digest()
	purpose := "cash.backup.retirement." + action + ".v1"
	person, err := r.current(ctx, assertion, purpose, p, result.PlanDigest)
	if err != nil || p.Generation <= 0 || (action != "reconcile" && person.Generation != p.Generation) || person.Generation < p.Generation {
		return result, ErrBackupRetirementUnavailable
	}
	ctx, release, err := r.Backups.lockBackupRecordUpdates(ctx)
	if err != nil {
		return result, err
	}
	defer release()
	op, exists, err := r.operation(ctx, p.Operation)
	if err != nil {
		return result, err
	}
	if exists && op.Digest != result.PlanDigest {
		return result, ErrBackupRetirementUnavailable
	}
	if exists && op.State == "completed" {
		result.State = "completed"
		return result, nil
	}
	if !exists && action != "execute" {
		return result, ErrBackupRetirementUnavailable
	}
	if exists && op.State == "attempted" && action != "resume" {
		return r.reconcileLocked(ctx, assertion, purpose, person, op)
	}
	if action == "reconcile" {
		result.State = op.State
		return result, nil
	}

	// 首次派发必须重读全部原记录及对象；续作只能沿已保存原版本，不能选择同名新版本。
	var records []BackupRecord
	var store RetainedBackupObjectStore
	if !exists || op.State == "prepared" {
		var actual BackupRetirementPlan
		actual, records, store, err = r.planLocked(ctx, p)
		if err != nil || actual.Digest() != result.PlanDigest {
			return result, ErrBackupRetirementUnavailable
		}
	} else {
		records, store, err = r.originalLocked(ctx, &p)
		if err != nil {
			return result, err
		}
		if err = r.keeperReady(ctx, store, p, true); err != nil {
			return result, err
		}
	}
	if exists && !backupRetirementClaimed(records, p) {
		return result, ErrBackupRetirementUnavailable
	}
	final, err := r.current(ctx, assertion, purpose, p, result.PlanDigest)
	if err != nil || final != person {
		return result, ErrBackupRetirementUnavailable
	}
	if !exists {
		op = backupRetirementOperation{1, p, result.PlanDigest, "prepared", person.Person, person.Version}
		for i := range records {
			if records[i].ID == p.Keeper {
				records[i].MetonRetentionPinned = true
			}
			if records[i].ID == p.Target {
				records[i].MetonRetirementOperation = p.Operation
			}
		}
		if err = r.save(ctx, records, op); err != nil {
			result.State = "unknown"
			return result, err
		}
	}
	// 对象保护是持久的，不因请求失败或人员撤权解除；未知保护不得继续删除。
	for _, version := range p.KeeperObjects {
		if err = store.ProtectVersion(ctx, version); err != nil {
			result.State = "prepared"
			return result, err
		}
	}
	if err = r.keeperReady(ctx, store, p, false); err != nil {
		result.State = "prepared"
		return result, err
	}
	final, err = r.current(ctx, assertion, purpose, p, result.PlanDigest)
	if err != nil || final != person {
		result.State = op.State
		return result, ErrBackupRetirementUnavailable
	}
	op.State = "attempted"
	if err = r.save(ctx, nil, op); err != nil {
		result.State = "unknown"
		return result, err
	}
	result.State = "unknown"
	for _, version := range p.TargetObjects {
		present, queryErr := store.VersionExists(ctx, version)
		if queryErr != nil {
			return result, queryErr
		}
		if !present {
			continue
		}
		final, err = r.current(ctx, assertion, purpose, p, result.PlanDigest)
		if err != nil || final != person {
			return result, ErrBackupRetirementUnavailable
		}
		if err = store.DeleteVersion(ctx, version); err != nil {
			return result, err
		}
	}
	return r.reconcileLocked(ctx, assertion, purpose, person, op)
}

/** 核对只查询原版本。保留副本或任一查询不可用时，不将未知改成完成。 */
func (r *ManagedBackupRetirement) reconcileLocked(ctx context.Context, assertion, purpose string, person BackupRetentionOperator, op backupRetirementOperation) (BackupRetirementReceipt, error) {
	result := BackupRetirementReceipt{op.Plan.Operation, "unknown", op.Digest}
	records, store, err := r.originalLocked(ctx, &op.Plan)
	if err != nil {
		return result, err
	}
	if !backupRetirementClaimed(records, op.Plan) {
		return result, ErrBackupRetirementUnavailable
	}
	if err = r.keeperReady(ctx, store, op.Plan, false); err != nil {
		return result, err
	}
	for _, version := range op.Plan.TargetObjects {
		present, queryErr := store.VersionExists(ctx, version)
		if queryErr != nil {
			return result, queryErr
		}
		if present {
			return result, nil
		}
	}
	final, err := r.current(ctx, assertion, purpose, op.Plan, op.Digest)
	if err != nil || final != person {
		return result, ErrBackupRetirementUnavailable
	}
	for i := range records {
		if records[i].ID == op.Plan.Target {
			records[i].Status = "retired"
		}
	}
	op.State = "completed"
	if err = r.save(ctx, records, op); err != nil {
		return result, err
	}
	result.State = "completed"
	return result, nil
}

/** 原操作与两份备份保护同次保存，缺任一部分不以旧回执补造执行资格。 */
func backupRetirementClaimed(records []BackupRecord, p BackupRetirementPlan) bool {
	target, keeper := false, false
	for _, record := range records {
		if record.ID == p.Target {
			target = record.MetonRetirementOperation == p.Operation
		}
		if record.ID == p.Keeper {
			keeper = record.MetonRetentionPinned
		}
	}
	return target && keeper
}

/** 未来格式、损坏回执和异参不能当作没有原操作。 */
func (r *ManagedBackupRetirement) operation(ctx context.Context, id string) (backupRetirementOperation, bool, error) {
	raw, err := r.Backups.settingRepo.GetValue(ctx, backupRetirementPrefix+id)
	// 原仓储用明确的 NotFound 表示首次操作；空行或读取故障不能冒充尚未受理。
	if errors.Is(err, ErrSettingNotFound) {
		return backupRetirementOperation{}, false, nil
	}
	if err != nil {
		return backupRetirementOperation{}, false, err
	}
	if raw == "" {
		return backupRetirementOperation{}, false, ErrBackupRetirementUnavailable
	}
	var value backupRetirementOperation
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if len(raw) > 1024*1024 || decoder.Decode(&value) != nil || decoder.Decode(new(any)) != io.EOF || value.Format != 1 ||
		value.Plan.Operation != id || value.Digest != value.Plan.Digest() ||
		(value.State != "prepared" && value.State != "attempted" && value.State != "completed") {
		return value, false, ErrBackupRetirementUnavailable
	}
	return value, true, nil
}

/** 复用原仓储的同次多键提交，避免已删对象但原目标认领或保留副本信息丢失。 */
func (r *ManagedBackupRetirement) save(ctx context.Context, records []BackupRecord, op backupRetirementOperation) error {
	raw, err := json.Marshal(op)
	if err != nil {
		return err
	}
	values := map[string]string{backupRetirementPrefix + op.Plan.Operation: string(raw)}
	if records != nil {
		raw, err = json.Marshal(records)
		if err != nil {
			return err
		}
		values[settingKeyBackupRecords] = string(raw)
	}
	return r.Backups.settingRepo.SetMultiple(ctx, values)
}

/** 仅原内容身份进入摘要，后续认领和保护不使同一原计划失效。 */
func backupRetentionRecordDigest(record BackupRecord) string {
	// 当前进度和保护标志不是原内容身份，原创建信息、分卷及保留策略必须保持。
	return backupRetirementDigest(struct {
		ID, Kind, File, Started, Key string
		Size                         int64
		Parts                        []BackupPart
		Monthly                      *BackupMonthlyArchive
	}{
		record.ID, record.BackupType, record.FileName, record.StartedAt, record.S3Key, record.SizeBytes, record.Parts, record.MonthlyArchive})
}

/** 位置参与计划绑定；秘密及其轮换不进入普通回执。 */
func backupRetentionLocation(cfg *BackupS3Config) string {
	return backupRetirementDigest(struct {
		Endpoint, Region, Bucket, Prefix string
		Path                             bool
	}{
		cfg.Endpoint, cfg.Region, cfg.Bucket, cfg.Prefix, cfg.ForcePathStyle})
}

/** 共享对象、运行中备份和别的原操作都不能由本次计划接管。 */
func (r *ManagedBackupRetirement) originalLocked(ctx context.Context, p *BackupRetirementPlan) ([]BackupRecord, RetainedBackupObjectStore, error) {
	records, err := r.Backups.loadRecordsLocked(ctx)
	if err != nil {
		return nil, nil, err
	}
	var target, keeper *BackupRecord
	seen := map[string]bool{}
	for i := range records {
		if seen[records[i].ID] {
			return nil, nil, ErrBackupRetirementUnavailable
		}
		seen[records[i].ID] = true
		if records[i].ID == p.Target {
			target = &records[i]
		}
		if records[i].ID == p.Keeper {
			keeper = &records[i]
		}
	}
	if target == nil || keeper == nil || target.MetonRetentionPinned || target.MonthlyArchive != nil ||
		(target.MetonRetirementOperation != "" && target.MetonRetirementOperation != p.Operation) || keeper.MetonRetirementOperation != "" ||
		target.Status != "completed" || keeper.Status != "completed" || target.RestoreStatus == "running" || keeper.RestoreStatus == "running" ||
		(p.TargetRecord != "" && backupRetentionRecordDigest(*target) != p.TargetRecord) ||
		(p.KeeperRecord != "" && backupRetentionRecordDigest(*keeper) != p.KeeperRecord) {
		return nil, nil, ErrBackupRetirementUnavailable
	}
	targetKeys := map[string]bool{}
	for _, key := range backupObjectKeys(target) {
		targetKeys[key] = true
	}
	for _, other := range records {
		if other.ID == target.ID {
			continue
		}
		for _, key := range backupObjectKeys(&other) {
			if targetKeys[key] {
				return nil, nil, ErrBackupRetirementUnavailable
			}
		}
	}
	cfg, err := r.Backups.loadS3Config(ctx)
	if err != nil || cfg == nil || !cfg.IsConfigured() || (p.Location != "" && backupRetentionLocation(cfg) != p.Location) {
		return nil, nil, ErrBackupRetirementUnavailable
	}
	// 原缓存不会感知外部还原后的配置；清理必须从本次已核对配置建原工厂客户端，不能给旧客户端贴新位置摘要。
	ordinary, err := r.Backups.storeFactory(ctx, cfg)
	if err != nil {
		return nil, nil, err
	}
	store, ok := ordinary.(RetainedBackupObjectStore)
	if !ok {
		return nil, nil, ErrBackupRetirementUnavailable
	}
	// 位置摘要必须与实际对象客户端取自同一份配置，不能另读一次可能已被替换的配置。
	if p.Location == "" {
		p.Location = backupRetentionLocation(cfg)
	}
	return records, store, nil
}

/** 原计划中的位置在每个当前许可边界复验；秘密轮换不改变位置，未知配置不能继续执行。 */
func (r *ManagedBackupRetirement) locationCurrent(ctx context.Context, p BackupRetirementPlan) bool {
	if p.Location == "" {
		return true
	}
	cfg, err := r.Backups.loadS3Config(ctx)
	return err == nil && cfg != nil && cfg.IsConfigured() && backupRetentionLocation(cfg) == p.Location
}

/** 两份副本都读取完整固定版本，不用列表、大小或旧校验值代替实际内容。 */
func (r *ManagedBackupRetirement) planLocked(ctx context.Context, p BackupRetirementPlan) (BackupRetirementPlan, []BackupRecord, RetainedBackupObjectStore, error) {
	records, store, err := r.originalLocked(ctx, &p)
	if err != nil {
		return p, nil, nil, err
	}
	var targetHash, keeperHash string
	var targetBytes, keeperBytes int64
	for _, record := range records {
		if record.ID != p.Target && record.ID != p.Keeper {
			continue
		}
		keys := backupObjectKeys(&record)
		if len(keys) == 0 || len(keys) > 1024 || record.SizeBytes <= 0 || record.SizeBytes > r.MaxBytes ||
			(len(record.Parts) > 0 && (record.S3Key != "" || len(keys) != len(record.Parts))) {
			return p, nil, nil, ErrBackupRetirementUnavailable
		}
		versions := make([]BackupObjectVersion, 0, len(keys))
		for _, key := range keys {
			version, err := store.CurrentVersion(ctx, key)
			if err != nil || version.Key != key || version.VersionID == "" || version.VersionID == "null" || len(version.VersionID) > 1024 || version.Size <= 0 {
				return p, nil, nil, ErrBackupRetirementUnavailable
			}
			versions = append(versions, version)
		}
		digest, size, err := r.content(ctx, store, versions)
		if err != nil || size != record.SizeBytes {
			return p, nil, nil, ErrBackupRetirementUnavailable
		}
		if record.ID == p.Target {
			p.TargetRecord, p.TargetObjects, targetHash, targetBytes = backupRetentionRecordDigest(record), versions, digest, size
		} else {
			p.KeeperRecord, p.KeeperObjects, keeperHash, keeperBytes = backupRetentionRecordDigest(record), versions, digest, size
		}
	}
	if targetHash == "" || targetHash != keeperHash || targetBytes != keeperBytes {
		return p, nil, nil, ErrBackupRetirementUnavailable
	}
	p.Content, p.Bytes = keeperHash, keeperBytes
	return p, records, store, nil
}

/** 有界流式比较，不把整份数据库归档载入内存。对象适配须遵守上下文取消。 */
func (r *ManagedBackupRetirement) content(ctx context.Context, store RetainedBackupObjectStore, objects []BackupObjectVersion) (string, int64, error) {
	hash := sha256.New()
	var size int64
	for _, version := range objects {
		if ctx.Err() != nil || version.Size <= 0 || version.Size > r.MaxBytes-size {
			return "", 0, ErrBackupRetirementUnavailable
		}
		body, err := store.ReadVersion(ctx, version)
		if err != nil {
			return "", 0, err
		}
		n, readErr := io.Copy(hash, io.LimitReader(body, version.Size+1))
		closeErr := body.Close()
		if readErr != nil || closeErr != nil || n != version.Size || ctx.Err() != nil {
			return "", 0, ErrBackupRetirementUnavailable
		}
		size += n
	}
	return hex.EncodeToString(hash.Sum(nil)), size, nil
}

/** 副本固定版本须仍可读且保持持久保护；明确续作还要重新核对全部内容。 */
func (r *ManagedBackupRetirement) keeperReady(ctx context.Context, store RetainedBackupObjectStore, p BackupRetirementPlan, readContent bool) error {
	if len(p.KeeperObjects) == 0 || len(p.KeeperObjects) > 1024 {
		return ErrBackupRetirementUnavailable
	}
	for _, version := range p.KeeperObjects {
		present, err := store.VersionExists(ctx, version)
		if err != nil || !present {
			return ErrBackupRetirementUnavailable
		}
		protected, err := store.VersionProtected(ctx, version)
		if err != nil || !protected {
			return ErrBackupRetirementUnavailable
		}
	}
	if readContent {
		digest, size, err := r.content(ctx, store, p.KeeperObjects)
		if err != nil || digest != p.Content || size != p.Bytes {
			return ErrBackupRetirementUnavailable
		}
	}
	return nil
}
