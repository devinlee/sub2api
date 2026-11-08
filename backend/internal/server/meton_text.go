package server

import (
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"sync"
)

// MetonTextIngress 在装配成功时才非空；普通构建及未配置托管构建均不开放模型路由。
type MetonTextIngress struct {
	Authenticate gin.HandlerFunc
	Control      *service.MetonModelControl
	GiftClosure  *service.MetonGiftClosure
	RestoredGift *service.MetonRestoredGiftControl
	Statements   *service.MetonStatements
	close        func()
	once         sync.Once
}

/** Close 沿原应用退出释放全部专用来源连接池，重复清理不重新执行。 */
func (m *MetonTextIngress) Close() {
	if m != nil {
		m.once.Do(func() {
			if m.close != nil {
				m.close()
			}
		})
	}
}
