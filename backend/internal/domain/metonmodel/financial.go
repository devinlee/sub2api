package metonmodel

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const FinancialRoute = "/meton/financial-observation"
const FinancialPermission = "meton.financial.observe"

type FinancialScope struct {
	Environment string `json:"environment"`
	Source      string `json:"source"`
	Epoch       int64  `json:"epoch"`
}
type FinancialTimes struct {
	ObservedAt time.Time `json:"observed_at"`
	ValidUntil time.Time `json:"valid_until"`
}
type FinancialUnit struct {
	Unit              string `json:"unit"`
	Held              string `json:"held"`
	GiftHeld          string `json:"gift_held"`
	PurchaseHeld      string `json:"purchase_held"`
	RefundHeld        string `json:"refund_held"`
	Shortfall         string `json:"shortfall"`
	ShortfallItems    int64  `json:"shortfall_items"`
	Pending           int64  `json:"pending_requests"`
	Dispatched        int64  `json:"dispatched_unsettled"`
	UnknownResults    int64  `json:"unknown_results"`
	UnknownFees       int64  `json:"unknown_fees"`
	HistoricalPending int64  `json:"historical_pending"`
	OldestPendingMS   int64  `json:"oldest_pending_ms"`
}
type FinancialObservation struct {
	Version            int             `json:"version"`
	State              string          `json:"state"`
	Scope              FinancialScope  `json:"scope"`
	Snapshot           FinancialTimes  `json:"snapshot"`
	Accounts           int64           `json:"accounts"`
	HistoricalAccounts int64           `json:"historical_accounts"`
	Units              []FinancialUnit `json:"units"`
}

var financialAmount = regexp.MustCompile(`^(0|[1-9][0-9]{0,29})\.[0-9]{8}$`)

/** 数据库 UTC 字符串与 Go 的 Z 写法等价；字段完整性单独检查，不能把缺项解析成零。 */
func decodeFinancial(raw []byte, v *FinancialObservation) bool {
	if len(raw) == 0 || len(raw) > 32768 || !utf8.Valid(raw) {
		return false
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	if resultTokens(d, 0) != nil {
		return false
	}
	if _, err := d.Token(); err != io.EOF {
		return false
	}
	d = json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil {
		return false
	}
	fields := func(raw []byte, names string) map[string]json.RawMessage {
		var object map[string]json.RawMessage
		keys := strings.Fields(names)
		if json.Unmarshal(raw, &object) != nil || len(object) != len(keys) {
			return nil
		}
		for _, key := range keys {
			value, ok := object[key]
			if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
				return nil
			}
		}
		return object
	}
	root := fields(raw, "version state scope snapshot accounts historical_accounts units")
	if root == nil || fields(root["scope"], "environment source epoch") == nil || fields(root["snapshot"], "observed_at valid_until") == nil {
		return false
	}
	var units []json.RawMessage
	if json.Unmarshal(root["units"], &units) != nil {
		return false
	}
	for _, unit := range units {
		if fields(unit, "unit held gift_held purchase_held refund_held shortfall shortfall_items pending_requests dispatched_unsettled unknown_results unknown_fees historical_pending oldest_pending_ms") == nil {
			return false
		}
	}
	return true
}

/** 验证 SQL 固定形状和资金精度；响应只返回已检查字段，不透传未知明细。 */
func ReadFinancialObservation(raw []byte, scope FinancialScope, now time.Time) (*FinancialObservation, error) {
	var v FinancialObservation
	if !decodeFinancial(raw, &v) || v.Version != 1 || v.State != "observed" || v.Scope != scope ||
		v.Accounts < 0 || v.HistoricalAccounts < 0 || v.HistoricalAccounts > v.Accounts || v.Units == nil || len(v.Units) > 16 ||
		v.Snapshot.ObservedAt.IsZero() || v.Snapshot.ObservedAt.After(now) || v.Snapshot.ValidUntil.Sub(v.Snapshot.ObservedAt) != 5*time.Second || !now.Before(v.Snapshot.ValidUntil) {
		return nil, ErrReference
	}
	seen := map[string]bool{}
	for _, u := range v.Units {
		if u.Unit == "" || len(u.Unit) > 120 || strings.TrimSpace(u.Unit) != u.Unit || seen[u.Unit] {
			return nil, ErrReference
		}
		seen[u.Unit] = true
		for _, s := range []string{u.Held, u.GiftHeld, u.PurchaseHeld, u.RefundHeld, u.Shortfall} {
			if !financialAmount.MatchString(s) {
				return nil, ErrReference
			}
		}
		amount := func(s string) *big.Int { n, _ := new(big.Int).SetString(strings.ReplaceAll(s, ".", ""), 10); return n }
		if new(big.Int).Add(amount(u.GiftHeld), amount(u.PurchaseHeld)).Cmp(amount(u.Held)) != 0 || u.ShortfallItems < 0 || u.Pending < 0 ||
			u.Dispatched < 0 || u.Dispatched > u.Pending || u.UnknownResults < 0 || u.UnknownResults > u.Pending || u.UnknownFees < 0 || u.UnknownFees > u.Pending ||
			u.HistoricalPending < 0 || u.HistoricalPending > u.Pending || u.OldestPendingMS < 0 {
			return nil, ErrReference
		}
	}
	return &v, nil
}

// FinancialAccess 只由原管理鉴权结果与内存凭据派生，不接受客户端提供的数据库证明。
type FinancialAccess struct {
	KeyID     string
	CreatorID int64
	Revision  time.Time
	Until     time.Time
	Witness   string
}

/** 把一次只读权限绑定到固定来源和短期限，数据库不接收原密钥。 */
func BindFinancialAccess(key, id string, creator int64, revision, until time.Time, scope FinancialScope) (FinancialAccess, bool) {
	parts := strings.Split(key, "_")
	if creator < 1 || revision.IsZero() || len(parts) != 4 || parts[0] != "adm" || parts[1] != "sc" || parts[2] != id || len(id) != 24 || !digest.MatchString(parts[3]) {
		return FinancialAccess{}, false
	}
	until = time.UnixMilli(until.UnixMilli()).UTC()
	h := sha256.Sum256([]byte(key))
	fields := []string{"meton.financial.http.v1", hex.EncodeToString(h[:]), scope.Environment, scope.Source, strconv.FormatInt(scope.Epoch, 10), id, strconv.FormatInt(creator, 10), strconv.FormatInt(until.UnixMilli(), 10)}
	proof := sha256.Sum256([]byte(strings.Join(fields, "|")))
	return FinancialAccess{id, creator, revision, until, hex.EncodeToString(proof[:])}, true
}
