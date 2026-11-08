//go:build meton_managed

package metonledger

import (
	"context"
	"regexp"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

// SupplierReturnKey 唯一定位供应方原结算行，并固定它在本来源对应的请求费项。
type SupplierReturnKey struct {
	Item           string `json:"item"`
	OriginalReport string `json:"original_report"`
	Provider       string `json:"provider"`
	Reference      string `json:"reference"`
}

// SupplierCostReturn 的币种和金额只用于供应成本核对。
type SupplierCostReturn struct {
	SupplierReturnKey
	Currency string `json:"currency"`
	Amount   string `json:"amount"`
}

type SupplierReturnReceipt struct {
	Origin metonfee.Origin `json:"origin"`
	SupplierCostReturn
}

var costCurrency = regexp.MustCompile("^[A-Z]{3}$")

// RecordSupplierReturn 用受限的成本确认身份记录供应方原始凭证。
func (l *TextLedger) RecordSupplierReturn(ctx context.Context, o metonfee.Origin, proof SupplierCostReturn) (*SupplierReturnReceipt, error) {
	return l.supplierReturn(ctx, o, proof.SupplierReturnKey, &proof)
}

// FindSupplierReturn 在丢失回应后只查原结算行。未能核实的费用仍为未知。
func (l *TextLedger) FindSupplierReturn(ctx context.Context, o metonfee.Origin, key SupplierReturnKey) (*SupplierReturnReceipt, error) {
	return l.supplierReturn(ctx, o, key, nil)
}

func (l *TextLedger) supplierReturn(ctx context.Context, o metonfee.Origin, key SupplierReturnKey, expected *SupplierCostReturn) (*SupplierReturnReceipt, error) {
	args := []any{key.Item, key.OriginalReport, key.Provider, key.Reference}
	query := "find_supplier_return($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)"
	if expected != nil {
		query = "record_supplier_return($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)"
		args = append(args, expected.Currency, expected.Amount)
	}
	var receipt SupplierReturnReceipt
	if err := l.feeCommand(ctx, o, query, args, &receipt); err != nil {
		return nil, err
	}
	value, ok := financialNumber(receipt.Amount)
	if receipt.Origin != o || receipt.SupplierReturnKey != key || !ok || value.Sign() <= 0 || !costCurrency.MatchString(receipt.Currency) ||
		(expected != nil && receipt.SupplierCostReturn != *expected) {
		return nil, errOriginalFee
	}
	return &receipt, nil
}
