//go:build meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"os"
)

/** ProvideMetonResultControl 与正文转发分开装配，清理由原服务器生命周期接管。 */
func ProvideMetonResultControl(accounts service.AccountRepository) (*MetonResultIngress, error) {
	control, close, err := metonentry.OpenResultControl(os.Getenv("METON_MANAGED_RESULT_CONFIG"), accounts)
	if err != nil {
		return nil, err
	}
	shortfall, closeShortfall, err := metonentry.OpenShortfallControl(os.Getenv("METON_MANAGED_SHORTFALL_CONFIG"))
	if err != nil {
		close()
		return nil, err
	}
	correction, closeCorrection, err := metonentry.OpenCorrectionControl(os.Getenv("METON_MANAGED_CORRECTION_CONFIG"))
	if err != nil {
		closeShortfall()
		close()
		return nil, err
	}
	financial, closeFinancial, err := metonentry.OpenFinancialControl(os.Getenv("METON_MANAGED_FINANCIAL_CONFIG"))
	if err != nil {
		closeCorrection()
		closeShortfall()
		close()
		return nil, err
	}
	restored, closeRestored, err := metonentry.OpenRestoredShortfallControl(os.Getenv("METON_MANAGED_RESTORED_SHORTFALL_CONFIG"))
	if err != nil {
		closeFinancial()
		closeCorrection()
		closeShortfall()
		close()
		return nil, err
	}
	return &MetonResultIngress{Control: control, Shortfall: shortfall, RestoredShortfall: restored, Correction: correction, Financial: financial,
		close: func() { closeRestored(); closeFinancial(); closeCorrection(); closeShortfall(); close() }}, nil
}
