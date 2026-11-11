package admin

import (
	"io"
	"mime"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/adminaccess"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

/** 仅在监听前装配，复用本处理器已有的唯一 BackupService，不接入普通删除方法。 */
func (h *BackupHandler) SetMetonBackupRetirement(configured *service.ManagedBackupRetirement) {
	h.retirement = nil
	h.retirementBudget = nil
	if !service.MetonManagedBuild || configured == nil || configured.Authority == nil || h.backupService == nil {
		return
	}
	copy := *configured
	copy.Backups = h.backupService
	h.retirement = &copy
	h.retirementBudget = make(chan struct{}, 4)
}

/** 固定路由决定用途；人员证明只经请求头传递，不作为待保存计划字段。 */
func (h *BackupHandler) MetonBackupRetirement(action string) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		source, ok := service.MetonSource()
		key, enabled := source.BackupRetirementKeyID()
		principal := adminaccess.FromContext(c.Request.Context())
		if !ok || !enabled || principal == nil || principal.KeyID != key || !adminaccess.RouteAllowed(principal.Policy, c.Request.Method, c.FullPath()) {
			response.Forbidden(c, "backup retirement unavailable")
			return
		}
		if action != "inspect" && action != "execute" && action != "reconcile" && action != "resume" {
			response.Forbidden(c, "backup retirement unavailable")
			return
		}
		if h.retirement == nil || h.retirementBudget == nil {
			response.Error(c, 503, "backup retirement unavailable")
			return
		}
		select {
		case h.retirementBudget <- struct{}{}:
			defer func() { <-h.retirementBudget }()
		default:
			response.Error(c, 429, "backup retirement busy")
			return
		}
		media, _, err := mime.ParseMediaType(c.GetHeader("Content-Type"))
		proof := c.Request.Header.Values("X-Meton-Operator-Assertion")
		if c.Request.Method != http.MethodPost || c.Request.URL.RequestURI() != c.FullPath() ||
			c.FullPath() != "/api/v1/admin"+service.BackupRetirementRoute+action || err != nil || media != "application/json" ||
			c.GetHeader("Content-Encoding") != "" || len(c.Request.Cookies()) != 0 || len(c.Request.Header.Values("Idempotency-Key")) != 0 ||
			len(proof) != 1 || len(proof[0]) == 0 || len(proof[0]) > 8185 || c.Request.ContentLength > 768*1024 {
			response.BadRequest(c, "invalid backup retirement request")
			return
		}
		raw, err := io.ReadAll(io.LimitReader(c.Request.Body, 768*1024+1))
		var plan service.BackupRetirementPlan
		if err != nil || len(raw) > 768*1024 || service.ReadBackupRetirementPlan(raw, &plan) != nil || plan.Format != 1 ||
			plan.Environment != source.Environment || plan.Source != source.Source || plan.Environment != h.retirement.Environment || plan.Source != h.retirement.Source {
			response.BadRequest(c, "invalid backup retirement plan")
			return
		}
		if action == "inspect" {
			expected := service.BackupRetirementPlan{Format: 1, Operation: plan.Operation, Environment: plan.Environment, Source: plan.Source, Target: plan.Target, Keeper: plan.Keeper}
			if plan.Digest() != expected.Digest() {
				response.BadRequest(c, "invalid backup inspection plan")
				return
			}
			inspected, err := h.retirement.Inspect(c.Request.Context(), proof[0], plan.Operation, plan.Target, plan.Keeper)
			if err != nil {
				response.Error(c, 503, "backup inspection unconfirmed")
				return
			}
			response.Success(c, inspected)
			return
		}
		var receipt service.BackupRetirementReceipt
		switch action {
		case "execute":
			receipt, err = h.retirement.Execute(c.Request.Context(), proof[0], plan)
		case "reconcile":
			receipt, err = h.retirement.Reconcile(c.Request.Context(), proof[0], plan)
		case "resume":
			receipt, err = h.retirement.Resume(c.Request.Context(), proof[0], plan)
		}
		if err != nil {
			// 可能已有部分对象删除，失败不能宣称全部保留，也不能自动续删。
			c.JSON(503, gin.H{"error": "backup_retirement_unconfirmed", "operation": plan.Operation, "state": "unknown"})
			return
		}
		response.Success(c, receipt)
	}
}
