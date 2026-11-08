//go:build meton_managed

package server

import (
	"github.com/Wei-Shaw/sub2api/internal/repository/metonentry"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"os"
)

/** ProvideMetonTextIngress 由独立受限来源池装配，不使用原生全能资金连接代替。 */
func ProvideMetonTextIngress(keys *service.APIKeyService, groups service.GroupRepository) (*MetonTextIngress, error) {
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
	closeQueries := func() { closeRestoredGift(); closeStatements(); closeGift(); closeObservation() }
	result := &MetonTextIngress{GiftClosure: gift, RestoredGift: restoredGift, Statements: statements, close: closeQueries}
	path := os.Getenv("METON_MANAGED_TEXT_CONFIG")
	if path == "" {
		return result, nil
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
	return result, nil
}
