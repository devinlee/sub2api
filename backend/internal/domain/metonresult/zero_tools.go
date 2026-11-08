//go:build meton_managed

package metonresult

/** zeroCounters 要求每个已声明的计数在原报文中确实为整数零，缺项和 null 均不成立。 */
func zeroCounters(fields object, names ...string) bool {
	for _, name := range names {
		value, ok := integer(fields[name])
		if !ok || value != 0 {
			return false
		}
	}
	return true
}

/** zeroHostedTools 仅识别已录制的完整容量结构。实际图片、搜索或未来扩展须使用覆盖其用量的价格。 */
func zeroHostedTools(raw []byte) bool {
	tools := obj(raw)
	search := obj(tools["web_search"])
	image := obj(tools["image_gen"])
	if len(tools) != 2 || len(search) != 1 || !zeroCounters(search, "num_requests") ||
		len(image) != 5 || !zeroCounters(image, "input_tokens", "output_tokens", "total_tokens") {
		return false
	}
	for _, side := range []string{"input_tokens_details", "output_tokens_details"} {
		details := obj(image[side])
		if len(details) != 2 || !zeroCounters(details, "image_tokens", "text_tokens") {
			return false
		}
	}
	return true
}
