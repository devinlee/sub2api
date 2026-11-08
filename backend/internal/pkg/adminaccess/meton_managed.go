//go:build meton_managed

package adminaccess

import "github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"

// 普通版本不展示托管权限；专用版本沿用原权限目录、持有者及逐路由复验。
func init() {
	definitions = append(definitions,
		permissionDefinition{Permission{"meton.restored-gifts.terminate", "按原注销决定核销恢复赠送", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/gift-restoration/terminate"}},
		permissionDefinition{Permission{"meton.restored-gifts.read", "只读恢复后的原赠送注销", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/gift-restoration/inspect"}},
		permissionDefinition{Permission{"meton.restored-gifts.reconcile", "接续恢复后的原赠送核销", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/gift-restoration/reconcile"}},
		permissionDefinition{Permission{"meton.restored-shortfalls.approve", "重新审核恢复后的原差额", "Meton", "global"}, []string{"POST " + metonmodel.RestoredShortfallRoute + "approve"}},
		permissionDefinition{Permission{"meton.restored-shortfalls.apply", "执行当前批准的恢复差额", "Meton", "global"}, []string{"POST " + metonmodel.RestoredShortfallRoute + "apply"}},
		permissionDefinition{Permission{"meton.restored-shortfalls.read", "只读恢复差额原批准和结果", "Meton", "global"}, []string{"POST " + metonmodel.RestoredShortfallRoute + "resolution", "POST " + metonmodel.RestoredShortfallRoute + "original"}},
		permissionDefinition{Permission{metonmodel.FinancialPermission, "只读来源财务汇总", "Meton", "global"}, []string{"GET " + metonmodel.FinancialRoute}},
		permissionDefinition{Permission{"meton.corrections.read", "核对原消费批次和裁决", "Meton", "global"}, []string{"POST " + metonmodel.CorrectionRoute + "basis", "POST " + metonmodel.CorrectionRoute + "resolution"}},
		permissionDefinition{Permission{"meton.corrections.approve", "按原批次批准消费纠正", "Meton", "global"}, []string{"POST " + metonmodel.CorrectionRoute + "approve"}},
		permissionDefinition{Permission{"meton.corrections.apply", "执行已批准的原消费纠正", "Meton", "global"}, []string{"POST " + metonmodel.CorrectionRoute + "apply"}},
		permissionDefinition{Permission{"meton.shortfalls.apply", "按原费用结清已确认差额", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall/apply"}},
		permissionDefinition{Permission{"meton.shortfalls.read", "只读原差额处置回执", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall/resolution"}},
		permissionDefinition{Permission{"meton.results.observe", "登记原供应结果核对证明", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/observe"}},
		permissionDefinition{Permission{"meton.results.apply", "按批准选择原结果证明结算", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/apply"}},
		permissionDefinition{Permission{"meton.results.read", "只读原结果证明和原结算", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/proof", "POST /meton/managed-accounts/:operation/model-calls/:caller/:request/reconciliation/resolution"}},
		permissionDefinition{Permission{"meton.statements.read", "只读原账户一致截点和账单分页", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/statements/open", "POST /meton/managed-accounts/:operation/statements/page"}},
		permissionDefinition{Permission{"meton.gifts.inspect", "查询原赠送注销范围", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/gift-closure/inspect"}},
		permissionDefinition{Permission{"meton.gifts.close", "按最终关闭事实结清原赠送", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/gift-closure/terminate", "POST /meton/managed-accounts/:operation/gift-closure/reconcile"}},
		permissionDefinition{Permission{"meton.models.inspect", "只读原模型受理、终局和费用事件", "Meton", "global"}, []string{"GET /meton/managed-accounts/:operation/model-calls/:caller/:request", "GET /meton/managed-accounts/:operation/model-calls/:caller/:request/fees/:event", "GET /meton/managed-accounts/:operation/model-calls/:caller/:request/result", "GET /meton/managed-accounts/:operation/model-calls/:caller/:request/execution"}},
		permissionDefinition{Permission{"meton.models.cancel", "请求取消原模型调用，释放仅由来源裁决", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/model-calls/:caller/:request/cancel"}},
		permissionDefinition{Permission{"meton.grants.redeem", "向原账户兑现初始赠送", "Meton", "global"}, []string{"POST /meton/managed-accounts/:operation/grants/:eligibility"}},
		permissionDefinition{Permission{"meton.grants.inspect", "只读初始赠送原凭证", "Meton", "global"}, []string{"GET /meton/managed-accounts/:operation/grants/:eligibility"}},
		permissionDefinition{Permission{"meton.managed.create", "建立托管个人账户", "Meton", "global"}, []string{"POST /meton/managed-accounts"}},
		permissionDefinition{Permission{"meton.managed.read", "只读托管原创建", "Meton", "global"}, []string{"GET /meton/managed-accounts/:operation"}},
		permissionDefinition{Permission{"meton.funds.inspect", "查询原账户注销资金预查", "Meton", "global"}, []string{"GET /meton/managed-accounts/:operation/funds"}},
		permissionDefinition{Permission{"meton.keys.issue", "签发托管会话 Key", "Meton", "global"}, []string{"POST /meton/managed-keys"}},
		permissionDefinition{Permission{"meton.keys.inspect", "只读原会话 Key 状态", "Meton", "global"}, []string{"GET /meton/managed-keys/:operation", "GET /meton/managed-keys/:operation/retirement", "GET /meton/session-closures/:operation", "GET /meton/session-closures/:operation/keys/:binding"}},
		permissionDefinition{Permission{"meton.sessions.close", "结束原托管会话", "Meton", "global"}, []string{"POST /meton/session-closures/:operation"}},
		permissionDefinition{Permission{"meton.keys.rotate", "按需停用原会话 Key", "Meton", "global"}, []string{"POST /meton/managed-keys/:operation/retirement"}},
	)
}
