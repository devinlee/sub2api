package service

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

const RestoredGiftRoute = "/meton/managed-accounts/:operation/gift-restoration/"

/** 原关闭范围与当前权限分开，读取也必须说明预期的原最终决定。 */
type MetonRestoredGiftRequest struct {
	Version  int              `json:"version"`
	Epoch    int64            `json:"epoch"`
	UntilMS  int64            `json:"until_ms"`
	Original MetonGiftRequest `json:"original"`
}
type MetonRestoredGiftReceipt struct {
	Version  int               `json:"version"`
	Action   string            `json:"action"`
	Epoch    int64             `json:"epoch"`
	Original *MetonGiftReceipt `json:"original"`
}

/** 复用原赠送协议的严格解析；不接受新金额、替代决定或调用者自报的管理身份。 */
func ReadMetonRestoredGift(action string, raw []byte) (*MetonRestoredGiftRequest, error) {
	var q MetonRestoredGiftRequest
	if decodeGift(raw, &q) != nil || (action != "inspect" && action != "reconcile" && action != "terminate") || q.Version != 1 || q.UntilMS < 1 {
		return nil, ErrMetonClosed
	}
	o := q.Original.Scope
	source := MetonManagedSource{Environment: o.Environment, Source: o.Source, Epoch: o.Epoch}
	if !metonName.MatchString(o.Environment) || !metonName.MatchString(o.Source) || o.Epoch < 1 || q.Epoch <= o.Epoch ||
		!source.ValidClaim(&o.MetonManagedClaim) || o.RemoteUser < 1 || o.SourceMarker == uuid.Nil || o.Eligibility == uuid.Nil || !q.Original.Final.Valid() {
		return nil, ErrMetonClosed
	}
	return &q, nil
}

type MetonRestoredGiftAccess struct {
	KeyID     string
	CreatorID int64
	Revision  time.Time
	Until     time.Time
	Witness   string
}

/** 由原生认证结果生成短时证明；秘密不进入来源账本或请求正文。 */
func BindMetonRestoredGiftAccess(key, id string, creator int64, revision, until time.Time, action string, q MetonRestoredGiftRequest) (MetonRestoredGiftAccess, bool) {
	var empty MetonRestoredGiftAccess
	raw, e := json.Marshal(q)
	if _, err := ReadMetonRestoredGift(action, raw); e != nil || err != nil {
		return empty, false
	}
	parts := strings.Split(key, "_")
	if creator < 1 || revision.IsZero() || !metonKeyID.MatchString(id) || len(parts) != 4 || parts[0] != "adm" || parts[1] != "sc" || parts[2] != id ||
		len(parts[3]) != 64 || strings.Trim(parts[3], "0123456789abcdef") != "" {
		return empty, false
	}
	until = time.UnixMilli(until.UnixMilli()).UTC()
	secret := sha256.Sum256([]byte(key))
	o, f := q.Original.Scope, q.Original.Final
	fields := []string{"meton.restored-gift.http.v1", hex.EncodeToString(secret[:]), action, o.SourceMarker.String(), f.Decision.String(),
		strconv.FormatInt(q.Epoch, 10), strconv.FormatInt(o.Epoch, 10), f.Registration.String(), f.IdentityEvent.String(),
		strconv.FormatInt(f.SecurityVersion, 10), strconv.FormatInt(f.IdentityEpoch, 10), strconv.FormatInt(until.UnixMilli(), 10)}
	witness := sha256.Sum256([]byte(strings.Join(fields, "|")))
	return MetonRestoredGiftAccess{id, creator, revision, until, hex.EncodeToString(witness[:])}, true
}

/** SQL 返回原事实及当前代次；原回执仍走既有金额、范围和最终决定校验。 */
func restoredGiftReceipt(raw []byte, q MetonRestoredGiftRequest, action string) (*MetonRestoredGiftReceipt, error) {
	var snapshot struct {
		giftSnapshot
		AuthorityEpoch int64 `json:"authority_epoch"`
	}
	if decodeGift(raw, &snapshot) != nil || snapshot.AuthorityEpoch != q.Epoch {
		return nil, ErrMetonClosed
	}
	original, e := json.Marshal(snapshot.giftSnapshot)
	if e != nil {
		return nil, e
	}
	expected := q.Original
	if action == "inspect" {
		// 只读可报告尚无来源结果；发送资格仍由 Meton 原尝试记录决定。
		expected.Final = nil
	}
	receipt, e := giftReceipt(original, expected)
	if e != nil || receipt == nil || action == "reconcile" && receipt.Final == nil ||
		receipt.Final != nil && *receipt.Final != *q.Original.Final {
		return nil, ErrMetonClosed
	}
	return &MetonRestoredGiftReceipt{1, action, q.Epoch, receipt}, nil
}
