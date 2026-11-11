//go:build meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"os"
)

/** ProvideMetonTextIngress 由独立受限来源池装配，不使用原生全能资金连接代替。 */
func ProvideMetonTextIngress(keys *service.APIKeyService, groups service.GroupRepository, payments *service.PaymentConfigService) (*MetonTextIngress, error) {
	closeObservation, err := openMetonSourceObservation()
	if err != nil {
		return nil, err
	}
	gift, closeGift, err := metonentry.OpenGiftClosure(os.Getenv("METON_MANAGED_GIFT_CONFIG"))
	if err != nil {
		closeObservation()
		return nil, err
	}
	statements, closeStatements, err := metonentry.OpenStatements(os.Getenv("METON_MANAGED_STATEMENT_CONFIG"))
	if err != nil {
		closeGift()
		closeObservation()
		return nil, err
	}
	restoredGift, closeRestoredGift, err := metonentry.OpenRestoredGiftControl(os.Getenv("METON_MANAGED_RESTORED_GIFT_CONFIG"))
	if err != nil {
		closeStatements()
		closeGift()
		closeObservation()
		return nil, err
	}
	checkout, closeCheckout, err := metonentry.OpenCheckout(os.Getenv("METON_MANAGED_CHECKOUT_CONFIG"))
	if err != nil {
		closeRestoredGift()
		closeStatements()
		closeGift()
		closeObservation()
		return nil, err
	}
	notices, closeNotices, err := metonentry.OpenCashNotifications(os.Getenv("METON_MANAGED_CASH_NOTICE_CONFIG"), payments)
	if err != nil {
		closeCheckout()
		closeRestoredGift()
		closeStatements()
		closeGift()
		closeObservation()
		return nil, err
	}
	cashOperations, closeCashOperations, err := metonentry.OpenCashOperations(os.Getenv("METON_MANAGED_CASH_OPERATIONS_CONFIG"))
	if err != nil {
		closeNotices()
		closeCheckout()
		closeRestoredGift()
		closeStatements()
		closeGift()
		closeObservation()
		return nil, err
	}
	closeQueries := func() {
		closeCashOperations()
		closeNotices()
		closeCheckout()
		closeRestoredGift()
		closeStatements()
		closeGift()
		closeObservation()
	}
	cashArchive, closeArchive, err := metonentry.OpenCashArchive(os.Getenv("METON_MANAGED_CASH_ARCHIVE_CONFIG"))
	if err != nil {
		closeQueries()
		return nil, err
	}
	closeBeforeArchive := closeQueries
	closeQueries = func() { closeArchive(); closeBeforeArchive() }
	backupRetirement, closeBackups, err := metonentry.OpenBackupRetirement(os.Getenv("METON_MANAGED_BACKUP_RETIREMENT_CONFIG"))
	if err != nil {
		closeQueries()
		return nil, err
	}
	closeBeforeBackups := closeQueries
	closeQueries = func() { closeBackups(); closeBeforeBackups() }
	if checkout != nil && checkout.Route != nil {
		if payments == nil {
			closeQueries()
			return nil, service.ErrMetonClosed
		}
		checkout.Payments = payments
	}
	result := &MetonTextIngress{GiftClosure: gift, RestoredGift: restoredGift, Statements: statements, CashOperations: cashOperations, CashArchive: cashArchive, Checkout: checkout, CashNotifications: notices, close: closeQueries}
	result.BackupRetirement = backupRetirement
	startDelivery := func() (*MetonTextIngress, error) {
		stop, err := metonentry.StartPurchaseDelivery(os.Getenv("METON_MANAGED_PURCHASE_DELIVERY_CONFIG"), notices)
		if err != nil {
			result.Close()
			return nil, err
		}
		stopRefunds, err := metonentry.StartOriginalRefundDelivery(os.Getenv("METON_MANAGED_REFUND_DISPATCH_CONFIG"), notices)
		if err != nil {
			stop()
			result.Close()
			return nil, err
		}
		stopSettlement, err := metonentry.StartRefundSettlementWithAlternative(os.Getenv("METON_MANAGED_REFUND_SETTLEMENT_CONFIG"), os.Getenv("METON_MANAGED_ALTERNATIVE_CASH_CONFIG"), notices)
		if err != nil {
			stopRefunds()
			stop()
			result.Close()
			return nil, err
		}
		closeOriginal := result.close
		result.close = func() { stopSettlement(); stopRefunds(); stop(); closeOriginal() }
		return result, nil
	}
	path := os.Getenv("METON_MANAGED_TEXT_CONFIG")
	if path == "" {
		return startDelivery()
	}
	if keys == nil || groups == nil {
		closeQueries()
		return nil, service.ErrMetonClosed
	}
	entry, close, err := metonentry.Open(path, keys, groups)
	if err != nil {
		closeQueries()
		return nil, err
	}
	result.Authenticate, result.Control = middleware.MetonTextAuth(entry), entry.Control
	result.close = func() { close(); closeQueries() }
	return startDelivery()
}
