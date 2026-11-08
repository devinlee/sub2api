//go:build meton_managed

package service

import "github.com/Wei-Shaw/sub2api/internal/domain/metonexecution"

// 直接沿用已实现的严格解析；普通构建不会因此引入托管模型执行包。
var decodeGift = metonexecution.DecodeStrict
