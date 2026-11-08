package server

import (
	"github.com/Wei-Shaw/sub2api/internal/service"
	"sync"
)

type MetonResultIngress struct {
	Control           *service.MetonResultControl
	Shortfall         *service.MetonShortfallControl
	RestoredShortfall *service.MetonRestoredShortfallControl
	Correction        *service.MetonCorrectionControl
	Financial         *service.MetonFinancialControl
	close             func()
	once              sync.Once
}

/** Close 归还专用查询和结算资源，重复退出不再执行清理。 */
func (m *MetonResultIngress) Close() {
	if m != nil {
		m.once.Do(func() {
			if m.close != nil {
				m.close()
			}
		})
	}
}
