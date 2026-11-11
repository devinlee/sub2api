package payment

import "errors"

// ErrNativePrepayDeclined 仅表示原预下单请求收到明确拒绝，付款和额度各沿原业务记录核对。
var ErrNativePrepayDeclined = errors.New("native prepay declined")
