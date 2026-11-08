package metonmodel

import "encoding/json"

// Execution 只表示来源原发送裁决；dispatch_claimed 包括仍在执行、已结束或费用待核对，不能据此宣布免费。
type Execution struct {
	Version   int       `json:"version"`
	Admission Admission `json:"admission"`
	State     string    `json:"state"`
}

// Cancellation 在写入前绑定当前来源代次及已核对的原受理，不从供应端当前配置隐式补代次。
type Cancellation struct {
	Version   int       `json:"version"`
	Epoch     int64     `json:"epoch"`
	Admission Admission `json:"admission"`
}

/** ReadCancellation 拒绝恢复前的旧受理控制；历史费用核对另走只读和恢复流程。 */
func ReadCancellation(raw []byte) (*Cancellation, error) {
	var q Cancellation
	if decodeResult(raw, &q) != nil || q.Version != 1 || q.Epoch <= 0 || q.Admission.AcceptedEpoch != q.Epoch {
		return nil, ErrReference
	}
	admission, _ := json.Marshal(q.Admission)
	if _, err := ReadAdmission(admission); err != nil {
		return nil, ErrReference
	}
	return &q, nil
}

/** ReadExecution 拒绝缺字段、重复键和其他来源的形状，原身份仍沿不可变受理核对。 */
func ReadExecution(raw []byte) (*Execution, error) {
	var result Execution
	if decodeResult(raw, &result) != nil || result.Version != 1 ||
		(result.State != "prepared" && result.State != "dispatch_claimed" && result.State != "cancelled_unsent") {
		return nil, ErrReference
	}
	admission, _ := json.Marshal(result.Admission)
	if _, err := ReadAdmission(admission); err != nil {
		return nil, ErrReference
	}
	return &result, nil
}
