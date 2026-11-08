//go:build meton_managed

// Package metonledger 连接托管来源数据库的受限例程。每个连接池只应拥有其业务所需的执行权。
package metonledger

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"strconv"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonmodel"
	"github.com/Wei-Shaw/sub2api/internal/pkg/metonobserve"
)

// TextLedger 的部署身份来自托管服务配置；当前来源与代次仍由数据库复验。
type TextLedger struct {
	db                  *sql.DB
	environment, source string
	epoch               int64
	correctionAccess    *metonmodel.CorrectionAccess
}

func NewTextLedger(db *sql.DB) (*TextLedger, error) {
	environment, source := os.Getenv("METON_MANAGED_ENVIRONMENT"), os.Getenv("METON_MANAGED_SOURCE")
	epoch, err := strconv.ParseInt(os.Getenv("METON_MANAGED_EPOCH"), 10, 64)
	if db == nil || os.Getenv("METON_MANAGED_FUNDS_MODE") != "s2-source-v1" || environment == "" || source == "" || err != nil || epoch < 1 {
		return nil, errors.New("missing managed text ledger")
	}
	return &TextLedger{db: db, environment: environment, source: source, epoch: epoch}, nil
}

// 切回旧模式或恢复代次变化后，旧连接池不可继续发放资金或发送权。
func (l *TextLedger) conn(ctx context.Context) (*sql.Conn, error) {
	if !l.currentSource() {
		return nil, errors.New("managed text source changed")
	}
	return l.db.Conn(ctx)
}

/** currentSource 也用于提交回应后的复验，配置已换代的旧连接池不能交出发送许可。 */
func (l *TextLedger) currentSource() bool {
	return l != nil && os.Getenv("METON_MANAGED_FUNDS_MODE") == "s2-source-v1" && os.Getenv("METON_MANAGED_ENVIRONMENT") == l.environment &&
		os.Getenv("METON_MANAGED_SOURCE") == l.source && os.Getenv("METON_MANAGED_EPOCH") == strconv.FormatInt(l.epoch, 10)
}

// Call 是已验权的原请求，身份不含当前设备和轮换后的 Key。
type Call struct {
	User, Account, SourceMarker, Caller, OperationID string
}

// SessionKey 只携来源站已认证的原生编号与指纹，不将密钥材料放进预占记录。
type SessionKey struct {
	ID          int64
	Fingerprint string
}

// Estimate 的输入和输出上界须由供应端对实际待派发内容与执行规格确认。不能估价时不调用 Reserve。
type Estimate struct {
	Protocol, Model, Digest                string
	DigestVersion, InputBound, OutputBound int
}

type Allocation struct {
	CreditEvent string `json:"credit_event"`
	Kind        string `json:"kind"`
	Sequence    int64  `json:"sequence"`
	Amount      string `json:"amount"`
}

// Hold 记录原分配。取消之后仍能查询这些原始份额，当前是否还占用由原调用状态和资金事件确定。
type Hold struct {
	Origin                           metonfee.Origin
	Estimate                         Estimate
	AcceptedEpoch                    int64
	PriceVersion, Unit, Quote, State string
	Allocations                      []Allocation
}

func (l *TextLedger) args(c Call) []any {
	return []any{l.environment, l.source, l.epoch, c.User, c.Account, c.SourceMarker, c.Caller, c.OperationID}
}

const holdColumns = "SELECT request_id,environment,source,meton_user,account,source_marker,caller,operation_id,protocol,model,digest_version,input_digest,epoch_at_accept,price_version,unit,input_bound,output_bound,quote,state,allocations FROM meton_ledger."

func (l *TextLedger) receipt(ctx context.Context, c Call, query string, args []any) (*Hold, error) {
	return l.checkedReceipt(ctx, c, query, args, false)
}

/** 只给新受理增加迁移门禁；原事项查询、结算和取消不能因为准入关闭而失去核对入口。 */
func (l *TextLedger) checkedReceipt(ctx context.Context, c Call, query string, args []any, requireLimit bool) (*Hold, error) {
	// 先取专用连接，业务语句不会由连接池在另一条连接上重跑。
	conn, err := l.conn(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if requireLimit {
		if err = requireAccountLimit(ctx, conn); err != nil {
			return nil, err
		}
	}
	h, err := scanHold(conn.QueryRowContext(ctx, holdColumns+query, args...))
	if err != nil {
		return nil, err
	}
	if h.Origin.Environment != l.environment || h.Origin.Source != l.source || h.Origin.User != c.User || h.Origin.Account != c.Account ||
		h.Origin.SourceMarker != c.SourceMarker || h.Origin.Caller != c.Caller || h.Origin.OperationID != c.OperationID {
		return nil, errors.New("invalid original text owner")
	}
	return h, nil
}

/** scanHold 只解读同一来源回执；每个调用者仍须复验其原归属。 */
func scanHold(row *sql.Row) (*Hold, error) {
	var h Hold
	var encoded []byte
	err := row.Scan(&h.Origin.SourceRequestID, &h.Origin.Environment, &h.Origin.Source, &h.Origin.User, &h.Origin.Account, &h.Origin.SourceMarker,
		&h.Origin.Caller, &h.Origin.OperationID, &h.Estimate.Protocol, &h.Estimate.Model, &h.Estimate.DigestVersion, &h.Estimate.Digest,
		&h.AcceptedEpoch, &h.PriceVersion, &h.Unit, &h.Estimate.InputBound, &h.Estimate.OutputBound, &h.Quote, &h.State, &encoded)
	if err != nil {
		return nil, err
	}
	if h.Origin.SourceRequestID == "" || h.Origin.SourceMarker == "" || h.AcceptedEpoch < 1 || h.PriceVersion == "" || h.Unit == "" ||
		(h.State != "prepared" && h.State != "dispatch_claimed" && h.State != "cancelled_unsent") {
		return nil, errors.New("invalid original text receipt")
	}
	if err := json.Unmarshal(encoded, &h.Allocations); err != nil || len(h.Allocations) == 0 {
		return nil, errors.New("missing original source allocation")
	}
	return &h, nil
}

// Reserve 只提交一次数据库操作。网络异常没有可执行的回执，应以 Find 核对，不重试写入。
func (l *TextLedger) Reserve(ctx context.Context, c Call, key SessionKey, estimate Estimate) (*Hold, error) {
	args := append(l.args(c), key.ID, key.Fingerprint, estimate.Protocol, estimate.Model, estimate.DigestVersion, estimate.Digest, estimate.InputBound, estimate.OutputBound)
	h, err := l.checkedReceipt(ctx, c, "reserve_text($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)", args, true)
	if err == nil && h.Estimate != estimate {
		return nil, errors.New("original estimate differs")
	}
	return h, err
}

// Find 的连接可以只有查权。查无记录与连接中断均不产生释放或发出新请求的资格。
func (l *TextLedger) Find(ctx context.Context, c Call) (*Hold, error) {
	return l.receipt(ctx, c, "find_text_hold($1,$2,$3,$4,$5,$6,$7,$8)", l.args(c))
}

func (l *TextLedger) CancelUnsent(ctx context.Context, c Call, sourceRequestID string) (*Hold, error) {
	h, err := l.receipt(ctx, c, "cancel_unsent_text($1,$2,$3,$4,$5,$6,$7,$8,$9)", append(l.args(c), sourceRequestID))
	if err == nil && h.Origin.SourceRequestID != sourceRequestID {
		return nil, errors.New("different cancelled request")
	}
	return h, err
}

// ClaimDispatch 仅在数据库确认首次领取时返回 true。调用方不可把一次 Find 或者已经领取的结果解释成发送权。
func (l *TextLedger) ClaimDispatch(ctx context.Context, c Call, sourceRequestID string, key SessionKey) (bool, error) {
	args := append(l.args(c), sourceRequestID, key.ID, key.Fingerprint)
	var first bool
	conn, err := l.conn(ctx)
	if err != nil {
		return false, err
	}
	defer conn.Close()
	err = conn.QueryRowContext(ctx, "SELECT meton_ledger.claim_text_dispatch($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)", args...).Scan(&first)
	metonobserve.Claim(metonobserve.Scope{Environment: l.environment, Source: l.source, Epoch: l.epoch}, first, err)
	return err == nil && first, err
}
