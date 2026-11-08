//go:build unit && !meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
	"testing"
)

/** 普通构建不读取托管观察配置、不创建观察器或模型入口。 */
func TestRejectionObservationNativeClosed(t *testing.T) {
	t.Setenv("METON_MANAGED_OBSERVATION_CONFIG", "not-a-file")
	ingress, err := ProvideMetonTextIngress(nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ingress.Close()
	if ingress.Authenticate != nil || ingress.Control != nil || ingress.GiftClosure != nil || ingress.Statements != nil {
		t.Fatal("native managed ingress opened")
	}
	observer, err := metonobserve.Install(metonobserve.Scope{Environment: "s2-isolated", Source: "s2-managed", Epoch: 1}, "probe")
	if err != nil {
		t.Fatal("native installed observer")
	}
	observer.Close()
}
