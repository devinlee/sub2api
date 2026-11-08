//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"reflect"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

const correctionSelectionTypes = resultOriginArguments + ",uuid,uuid,uuid,uuid,uuid,integer,integer,text"
const correctionAccessTypes = ",text,bigint,timestamptz,bigint,text)"
const CorrectionBasisFunction = "meton_ledger.http_read_operations_correction_basis(" + resultOriginArguments + ",uuid,uuid,integer,jsonb" + correctionAccessTypes
const CorrectionReadFunction = "meton_ledger.http_find_operations_correction(" + correctionSelectionTypes + correctionAccessTypes
const CorrectionApproveFunction = "meton_ledger.http_approve_operations_correction(" + correctionSelectionTypes + ",text,boolean,jsonb,timestamptz,timestamptz" + correctionAccessTypes
const CorrectionApplyFunction = "meton_ledger.http_apply_operations_correction(" + correctionSelectionTypes + ",timestamptz" + correctionAccessTypes

type correctionStore struct {
	original                   *sql.DB
	reader, reviewer, executor *metonledger.TextLedger
}

/** 只允许四个相互独立的数据库身份。HTTP 写角色必须只能访问带管理权限锁的函数。 */
func newCorrectionControl(source service.MetonManagedSource, pools []*sql.DB, parallel int, timeout time.Duration, history *service.CorrectionKeyHistory) (*service.MetonCorrectionControl, error) {
	allowed := [][]string{{ExecutionReadFunction}, {CorrectionBasisFunction, CorrectionReadFunction}, {CorrectionApproveFunction}, {CorrectionApplyFunction}}
	if len(pools) != len(allowed) {
		return nil, service.ErrMetonClosed
	}
	var database string
	roles := map[string]bool{}
	ledgers := make([]*metonledger.TextLedger, 0, 3)
	for i, pool := range pools {
		db, role, err := checkPoolPermissions(pool, allowed[i])
		if err != nil || (i > 0 && db != database) || roles[role] || !giftPoolSeparate(pool) || !resultPoolPrivate(pool) {
			return nil, service.ErrMetonClosed
		}
		database = db
		roles[role] = true
		if i > 0 {
			l, err := metonledger.NewTextLedger(pool)
			if err != nil {
				return nil, err
			}
			ledgers = append(ledgers, l)
		}
	}
	store := &correctionStore{pools[0], ledgers[0], ledgers[1], ledgers[2]}
	return service.NewMetonCorrectionControl(source, store, parallel, timeout, history)
}

/** 原建号、账号、调用、来源请求及报价在办理前和交付前都要重新吻合。 */
func (s *correctionStore) ResolveCorrection(ctx context.Context, source service.MetonManagedSource, creation uuid.UUID, action string,
	q metonmodel.CorrectionRequest, access metonmodel.CorrectionAccess, guard func() bool) (json.RawMessage, error) {
	o := q.Admission.Origin
	current := func() bool {
		if guard == nil || !guard() {
			return false
		}
		var raw []byte
		if err := s.original.QueryRowContext(ctx, "SELECT meton_ledger.read_text_execution($1,$2,$3,$4,$5,$6)",
			source.Environment, source.Source, source.Epoch, creation, o.Caller, o.OperationID).Scan(&raw); err != nil {
			return false
		}
		execution, err := metonmodel.ReadExecution(raw)
		return err == nil && execution.State == "dispatch_claimed" && reflect.DeepEqual(execution.Admission, q.Admission) && guard()
	}
	if !current() {
		return nil, service.ErrMetonClosed
	}
	var value any
	var err error
	if action == "basis" {
		page, e := s.reader.WithCorrectionAccess(access).ReadOperationsCorrectionBasis(ctx, o, q.Item, q.Basis, q.Page.Limit, q.Page.Cursor)
		if e == nil && (page == nil || page.Report.Item.Unit != q.Admission.Pricing.Unit || page.Report.Item.PriceVersion != q.Admission.Pricing.Version) {
			return nil, service.ErrMetonClosed
		}
		value, err = page, e
	} else {
		k := q.Selection
		key := metonledger.OperationsCorrectionKey{CorrectionKey: metonledger.CorrectionKey{Item: q.Item, Basis: q.Basis, Decision: k.Decision},
			CaseID: k.CaseID, AttemptID: k.AttemptID, RulingVersion: k.RulingVersion, Generation: k.Generation, ApprovalDigest: k.ApprovalDigest}
		switch action {
		case "approve":
			a := q.Review
			lines := make([]metonledger.CorrectionSource, len(a.Sources))
			for i, v := range a.Sources {
				lines[i] = metonledger.CorrectionSource{CreditEvent: v.CreditEvent, Amount: v.Amount}
			}
			value, err = s.reviewer.WithCorrectionAccess(access).ApproveOperationsCorrection(ctx, o, key, metonledger.OperationsCorrectionApproval{
				PreviousDigest: a.PreviousDigest, Final: a.Final, Sources: lines, ValidUntil: time.UnixMilli(a.ValidUntilMS)}, access.Until)
		case "apply":
			value, err = s.executor.WithCorrectionAccess(access).ApplyOperationsCorrection(ctx, o, key, access.Until)
		case "resolution":
			value, err = s.reader.WithCorrectionAccess(access).FindOperationsCorrection(ctx, o, key)
		default:
			return nil, service.ErrMetonClosed
		}
	}
	if !current() {
		return nil, service.ErrMetonClosed
	}
	if (action == "basis" || action == "resolution") && errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	return json.Marshal(value)
}
