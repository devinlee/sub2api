//go:build !meton_managed

package service

/** decodeGift 普通构建没有该业务协议，不能靠解析结果开放候选路由。 */
func decodeGift(_ []byte, _ any) error { return ErrMetonClosed }
