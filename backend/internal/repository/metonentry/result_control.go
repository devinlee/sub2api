//go:build meton_managed

package metonentry

import (
	"context"
	"database/sql"
	"encoding/json"
	"reflect"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonprovider"
	"github.com/Wei-Shaw/sub2api/internal/repository/metonledger"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/google/uuid"
)

const resultOriginArguments = "text,text,bigint,uuid,uuid,uuid,text,uuid,uuid"
const ProviderOriginalFunction = "meton_ledger.find_provider_original(" + resultOriginArguments + ")"
const ResultProofReadFunction = "meton_ledger.find_text_result_proof(" + resultOriginArguments + ",uuid)"
const ResultResolutionReadFunction = "meton_ledger.find_text_resolution(" + resultOriginArguments + ")"
const ResultObserveFunction = "meton_ledger.record_text_result_proof(" + resultOriginArguments + ",uuid,text,jsonb,uuid,jsonb)"
const ResultApplyFunction = "meton_ledger.apply_text_result_proof(" + resultOriginArguments + ",uuid,uuid,uuid,text)"

type resultControlStore struct {
	original             *sql.DB
	read, observe, apply *metonledger.TextLedger
	provider             *metonprovider.Reader
	credentials          metonprovider.Credentials
}

/** NewResultControl 四个池沿既有原关联和账本函数接线；观察与结算不可共享运行身份。 */
func NewResultControl(original, read, observe, apply *sql.DB, provider *metonprovider.Reader, credentials metonprovider.Credentials) (*service.MetonResultControl, error) {
	if provider == nil || credentials == nil {
		return nil, service.ErrMetonClosed
	}
	pools := []*sql.DB{original, read, observe, apply}
	permissions := [][]string{{ExecutionReadFunction}, {ProviderOriginalFunction, ResultProofReadFunction, ResultResolutionReadFunction}, {ResultObserveFunction}, {ResultApplyFunction}}
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
	o, err := metonledger.NewTextLedger(observe)
	if err != nil {
		return nil, err
	}
	a, err := metonledger.NewTextLedger(apply)
	if err != nil {
		return nil, err
	}
	return service.NewMetonResultControl(&resultControlStore{original, r, o, a, provider, credentials}), nil
}

/** 运行角色只能调用列明例程，不能额外读取裸账号、秘密或账本表。 */
func resultPoolPrivate(pool *sql.DB) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var safe bool
	err := pool.QueryRowContext(ctx, `SELECT NOT EXISTS(SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','meton_ledger') AND c.relkind IN ('r','p') AND (has_table_privilege(current_user,c.oid,'SELECT') OR has_any_column_privilege(current_user,c.oid,'SELECT')))`).Scan(&safe)
	return err == nil && safe
}

/** Reconcile 原创建到原受理的关联必须由来源重读；持有请求 UUID 或自填所属账号均不能通过。 */
func (s *resultControlStore) Reconcile(ctx context.Context, source service.MetonManagedSource, creation uuid.UUID, action string, q metonmodel.ReconciliationRequest, guard func(context.Context) error) (json.RawMessage, error) {
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
	origin := q.Admission.Origin
	receipt := metonmodel.ReconciliationReceipt{Version: 1, Epoch: source.Epoch, Origin: origin, ReconciliationSelection: q.ReconciliationSelection, State: "observed"}
	key := metonledger.ResultResolutionKey{EvidenceID: q.EvidenceID, CaseID: q.CaseID, AttemptID: q.AttemptID, ApprovalDigest: q.ApprovalDigest}
	switch action {
	case "observe":
		proof, err := s.read.ObserveProvider(ctx, origin, q.EvidenceID, s.provider, s.credentials, s.observe, current)
		if err != nil {
			return nil, err
		}
		receipt.PriorEvent = proof.PriorEvent
	case "proof":
		original, err := s.read.FindProviderOriginal(ctx, origin)
		if err != nil {
			return nil, err
		}
		proof, err := s.read.FindResultProof(ctx, origin, metonledger.ResultProofKey{PriorEvent: original.PriorEvent, ContextHash: original.ContextHash, EvidenceID: q.EvidenceID})
		if err != nil {
			return nil, err
		}
		receipt.PriorEvent = proof.PriorEvent
	case "apply", "resolution":
		var result *metonledger.ResultResolution
		var err error
		if action == "apply" {
			// 与只读查证不同，本分支只执行一条原证明结算；提交未知原样返回，绝不在这里重试。
			if current(ctx) != nil {
				return nil, service.ErrMetonClosed
			}
			result, err = s.apply.ApplyResultProof(ctx, origin, key)
		} else {
			result, err = s.read.FindResultResolution(ctx, origin, key)
		}
		if err != nil {
			return nil, err
		}
		receipt.State = "resolved"
		receipt.PriorEvent = result.PriorEvent
		receipt.EventID = &result.Result.EventID
	default:
		return nil, service.ErrMetonClosed
	}
	if current(ctx) != nil {
		return nil, service.ErrMetonClosed
	}
	return json.Marshal(receipt)
}
