//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"reflect"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

const ShortfallReadFunction = "meton_ledger.find_text_shortfall(" + resultOriginArguments + ",uuid)"
const ShortfallApplyFunction = "meton_ledger.cover_text_shortfall(" + resultOriginArguments + ",uuid,uuid,uuid,uuid,uuid,text,timestamptz)"

type shortfallControlStore struct {
	original    *sql.DB
	read, apply *metonledger.TextLedger
}

/** 三种最小权限池必须同库且身份不同，不能继承裸表或其他资金权限。 */
func NewShortfallControl(original, read, apply *sql.DB, parallel int, timeout time.Duration) (*service.MetonShortfallControl, error) {
	pools := []*sql.DB{original, read, apply}
	permissions := [][]string{{ExecutionReadFunction}, {ShortfallReadFunction}, {ShortfallApplyFunction}}
	var identity string
	roles := map[string]bool{}
	for i, pool := range pools {
		found, role, err := checkPoolPermissions(pool, permissions[i])
		if err != nil || (i > 0 && found != identity) || roles[role] || !giftPoolSeparate(pool) || !resultPoolPrivate(pool) {
			return nil, service.ErrMetonClosed
		}
		identity = found
		roles[role] = true
	}
	r, err := metonledger.NewTextLedger(read)
	if err != nil {
		return nil, err
	}
	a, err := metonledger.NewTextLedger(apply)
	if err != nil {
		return nil, err
	}
	control := service.NewMetonShortfallControl(&shortfallControlStore{original, r, a}, parallel, timeout)
	if control == nil {
		return nil, service.ErrMetonClosed
	}
	return control, nil
}

/** 原创建到原受理的关系必须重读；结果查询没有补执行分支。 */
func (s *shortfallControlStore) Resolve(ctx context.Context, source service.MetonManagedSource, creation uuid.UUID, action string, q metonmodel.ShortfallRequest, guard func(context.Context) error) (json.RawMessage, error) {
	current := func(ctx context.Context) error {
		if guard == nil || guard(ctx) != nil {
			return service.ErrMetonClosed
		}
		var raw []byte
		o := q.Admission.Origin
		if err := s.original.QueryRowContext(ctx, "SELECT meton_ledger.read_text_execution($1,$2,$3,$4,$5,$6)", source.Environment, source.Source, source.Epoch, creation, o.Caller, o.OperationID).Scan(&raw); err != nil {
			return service.ErrMetonClosed
		}
		result, err := metonmodel.ReadExecution(raw)
		if err != nil || result.State != "dispatch_claimed" || !reflect.DeepEqual(result.Admission, q.Admission) || guard(ctx) != nil {
			return service.ErrMetonClosed
		}
		return nil
	}
	if current(ctx) != nil {
		return nil, service.ErrMetonClosed
	}
	o := q.Admission.Origin
	key := metonledger.ShortfallKey{ItemID: o.SourceRequestID, BasisEvent: q.BasisEvent, CommandID: q.CommandID, CaseID: q.CaseID, AttemptID: q.AttemptID, ApprovalDigest: q.ApprovalDigest}
	var result *metonledger.ShortfallResolution
	var err error
	switch action {
	case "apply":
		result, err = s.apply.CoverShortfall(ctx, o, key, time.UnixMilli(q.UntilMS))
	case "resolution":
		result, err = s.read.FindShortfall(ctx, o, key)
	default:
		return nil, service.ErrMetonClosed
	}
	if err != nil || current(ctx) != nil {
		return nil, service.ErrMetonClosed
	}
	if result == nil {
		// 查无不能补执行，也不能用空结构伪造没有扣款的终态。
		return nil, nil
	}
	project := func(p metonledger.FeePosting) metonmodel.ResultFee {
		return metonmodel.ResultFee{Reference: metonmodel.Fee{Version: p.Report.Version, Origin: p.Report.Origin, Item: p.Report.Item}, Funded: p.Funded, Uncovered: p.Uncovered}
	}
	receipt := metonmodel.ShortfallReceipt{Version: 1, Epoch: source.Epoch, Origin: o, ShortfallSelection: q.ShortfallSelection, State: result.State, Original: project(result.Basis)}
	if result.Result != nil {
		coverage := project(*result.Result)
		receipt.Coverage = &coverage
	}
	return json.Marshal(receipt)
}
