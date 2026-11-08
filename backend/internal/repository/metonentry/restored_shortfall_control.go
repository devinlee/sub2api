//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
	"reflect"
	"time"
)

const restoredShortfallAccessTypes = ",text,bigint,timestamptz,bigint,text)"
const RestoredShortfallReadFunction = "meton_ledger.http_find_restored_shortfall_approval(" + resultOriginArguments + ",uuid,integer,text" + restoredShortfallAccessTypes
const RestoredShortfallOriginalFunction = "meton_ledger.http_find_restored_shortfall_original(" + resultOriginArguments + ",uuid,text" + restoredShortfallAccessTypes
const RestoredShortfallApproveFunction = "meton_ledger.http_approve_restored_shortfall(" + resultOriginArguments + ",uuid,uuid,uuid,uuid,uuid,text,bigint,integer,text,text,timestamptz,timestamptz" + restoredShortfallAccessTypes
const RestoredShortfallApplyFunction = "meton_ledger.http_cover_restored_shortfall(" + resultOriginArguments + ",uuid,integer,text,timestamptz" + restoredShortfallAccessTypes

type restoredShortfallStore struct {
	original                   *sql.DB
	reader, reviewer, executor *metonledger.TextLedger
}

/** 只接四个独立最小权限池；HTTP 角色不能绕过同事务的原生管理权限核验。 */
func newRestoredShortfallControl(source service.MetonManagedSource, pools []*sql.DB, parallel int, timeout time.Duration, history *service.RestoredShortfallKeyHistory) (*service.MetonRestoredShortfallControl, error) {
	allowed := [][]string{{ExecutionReadFunction}, {RestoredShortfallReadFunction, RestoredShortfallOriginalFunction}, {RestoredShortfallApproveFunction}, {RestoredShortfallApplyFunction}}
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
			l, e := metonledger.NewTextLedger(pool)
			if e != nil {
				return nil, e
			}
			ledgers = append(ledgers, l)
		}
	}
	store := &restoredShortfallStore{pools[0], ledgers[0], ledgers[1], ledgers[2]}
	return service.NewMetonRestoredShortfallControl(source, store, parallel, timeout, history)
}

/** 当前创建映射与完整原受理每次都重读，不把恢复代次写回原派发事实。 */
func (s *restoredShortfallStore) ResolveRestoredShortfall(ctx context.Context, source service.MetonManagedSource, creation uuid.UUID, action string,
	q metonmodel.RestoredShortfallRequest, access metonmodel.RestoredShortfallAccess, guard func() bool) (json.RawMessage, error) {
	o := q.Admission.Origin
	current := func() bool {
		if guard == nil || !guard() {
			return false
		}
		var raw []byte
		if err := s.original.QueryRowContext(ctx, "SELECT meton_ledger.read_text_execution($1,$2,$3,$4,$5,$6)", source.Environment, source.Source, source.Epoch, creation, o.Caller, o.OperationID).Scan(&raw); err != nil {
			return false
		}
		result, err := metonmodel.ReadExecution(raw)
		return err == nil && result.State == "dispatch_claimed" && reflect.DeepEqual(result.Admission, q.Admission) && guard()
	}
	if !current() {
		return nil, service.ErrMetonClosed
	}
	var ledger *metonledger.TextLedger
	switch action {
	case "resolution", "original":
		ledger = s.reader
	case "approve":
		ledger = s.reviewer
	case "apply":
		ledger = s.executor
	default:
		return nil, service.ErrMetonClosed
	}
	var result any
	var err error
	if action == "original" {
		result, err = ledger.ReadRestoredShortfallOriginal(ctx, q, access)
	} else {
		result, err = ledger.RestoredShortfall(ctx, action, q, access)
	}
	if !current() {
		return nil, service.ErrMetonClosed
	}
	if (action == "resolution" || action == "original") && errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, service.ErrMetonClosed
	}
	return json.Marshal(result)
}
