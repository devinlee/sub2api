//go:build !meton_managed && unit

package server

import "testing"

/** 普通产物即使设置托管配置也不读取、不启用新资金控制。 */
func TestShortfallControlNativeFactory(t *testing.T) {
	t.Setenv("METON_MANAGED_RESULT_CONFIG", "not-a-file")
	t.Setenv("METON_MANAGED_SHORTFALL_CONFIG", "not-a-file")
	v, err := ProvideMetonResultControl(nil)
	if err != nil || v == nil || v.Control != nil || v.Shortfall != nil {
		t.Fatal("普通产物读取托管配置", err)
	}
	v.Close()
	v.Close()
}
