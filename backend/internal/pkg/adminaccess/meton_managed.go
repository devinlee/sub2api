//go:build meton_managed

package adminaccess

// 普通版本不展示托管权限；专用版本沿用原权限目录、持有者及逐路由复验。
func init() {
	definitions = append(definitions,
		permissionDefinition{Permission{"meton.managed.create", "建立托管个人账户", "Meton", "global"}, []string{"POST /meton/managed-accounts"}},
		permissionDefinition{Permission{"meton.managed.read", "只读托管原创建", "Meton", "global"}, []string{"GET /meton/managed-accounts/:operation"}},
	)
}
