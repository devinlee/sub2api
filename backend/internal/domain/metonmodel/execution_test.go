package metonmodel

import (
	"encoding/json"
	"strings"
	"testing"
)

/** 三种原裁决均绑定原受理，任何缺失或未知形状都不能升级为可以释放预占。 */
func TestMetonOriginalExecutionProtocol(t *testing.T) {
	for _, state := range []string{"prepared", "dispatch_claimed", "cancelled_unsent"} {
		raw, _ := json.Marshal(Execution{1, resultFixture().Admission, state})
		if _, err := ReadExecution(raw); err != nil {
			t.Fatal(state, err)
		}
	}
	raw, _ := json.Marshal(Execution{1, resultFixture().Admission, "cancelled_unsent"})
	valid := string(raw)
	for name, bad := range map[string]string{
		"unknown":      strings.Replace(valid, "cancelled_unsent", "unknown", 1),
		"missing":      strings.Replace(valid, `,"state":"cancelled_unsent"`, "", 1),
		"null":         strings.Replace(valid, `"state":"cancelled_unsent"`, `"state":null`, 1),
		"alias":        strings.Replace(valid, `"state":`, `"State":`, 1),
		"duplicate":    strings.Replace(valid, `"state":`, `"state":"prepared","state":`, 1),
		"extra":        strings.Replace(valid, `"state":`, `"refunded":true,"state":`, 1),
		"no-admission": `{"version":1,"admission":null,"state":"cancelled_unsent"}`,
		"version":      strings.Replace(valid, `"version":1`, `"version":2`, 1),
		"two-roots":    valid + "{}",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ReadExecution([]byte(bad)); err == nil {
				t.Fatal("invalid release evidence accepted")
			}
		})
	}
}

/** 写请求必须显式携带当前代次；不能从服务端当前环境补齐旧任务的身份。 */
func TestMetonOriginalCancellationProtocol(t *testing.T) {
	value := Cancellation{1, 1, resultFixture().Admission}
	encoded, _ := json.Marshal(value)
	valid := string(encoded)
	if _, err := ReadCancellation(encoded); err != nil {
		t.Fatal(err)
	}
	for name, bad := range map[string]string{
		"missing-epoch":     strings.Replace(valid, `,"epoch":1`, "", 1),
		"null-epoch":        strings.Replace(valid, `"epoch":1`, `"epoch":null`, 1),
		"duplicate":         strings.Replace(valid, `"epoch":1`, `"epoch":1,"epoch":1`, 1),
		"alias":             strings.Replace(valid, `"epoch":1`, `"Epoch":1`, 1),
		"old-admission":     strings.Replace(valid, `"epoch":1`, `"epoch":2`, 1),
		"extra":             strings.Replace(valid, `"epoch":1`, `"epoch":1,"release":true`, 1),
		"missing-admission": `{"version":1,"epoch":1}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ReadCancellation([]byte(bad)); err == nil {
				t.Fatal("invalid original cancellation accepted")
			}
		})
	}
}
