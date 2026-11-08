//go:build !meton_managed

package service

/** decodeStatement 普通版本不通过解析器带入托管执行依赖。 */
func decodeStatement(_ []byte, _ any) error { return ErrMetonClosed }
