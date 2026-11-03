//go:build meton_managed

package adminaccess

// 普通版本不展示托管权限；专用版本沿用原权限目录、持有者及逐路由复验。
func init() {
	definitions = append(definitions,
		permissionDefinition{Permission{"meton.managed.create", "建立托管个人账户", "Meton", "global"}, []string{"POST /meton/managed-accounts"}},
		permissionDefinition{Permission{"meton.managed.read", "只读托管原创建", "Meton", "global"}, []string{"GET /meton/managed-accounts/:operation"}},
		permissionDefinition{Permission{"meton.funds.inspect", "查询原账户注销资金预查", "Meton", "global"}, []string{"GET /meton/managed-accounts/:operation/funds"}},
		permissionDefinition{Permission{"meton.keys.issue", "签发托管会话 Key", "Meton", "global"}, []string{"POST /meton/managed-keys"}},
		permissionDefinition{Permission{"meton.keys.inspect", "只读原会话 Key 状态", "Meton", "global"}, []string{"GET /meton/managed-keys/:operation", "GET /meton/managed-keys/:operation/retirement", "GET /meton/session-closures/:operation", "GET /meton/session-closures/:operation/keys/:binding"}},
		permissionDefinition{Permission{"meton.sessions.close", "结束原托管会话", "Meton", "global"}, []string{"POST /meton/session-closures/:operation"}},
		permissionDefinition{Permission{"meton.keys.rotate", "按需停用原会话 Key", "Meton", "global"}, []string{"POST /meton/managed-keys/:operation/retirement"}},
	)
}
