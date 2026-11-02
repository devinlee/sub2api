//go:build !meton_managed

package service

// 原生产线保持原行为，未编译托管模式时不装配该管理入口。
const MetonManagedBuild = false
