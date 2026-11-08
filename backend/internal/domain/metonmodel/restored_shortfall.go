package metonmodel

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
	"strconv"
	"strings"
	"time"
)

const RestoredShortfallRoute = "/meton/managed-accounts/:operation/model-calls/:caller/:request/shortfall-restoration/"

// 当前批准只引用原子命令；不改受理、原费用或原审核摘要。
type RestoredShortfallAuthority struct {
	OriginalEpoch int64  `json:"original_epoch"`
	Generation    int32  `json:"generation"`
	ReviewDigest  string `json:"review_digest"`
}
type RestoredShortfallReview struct {
	PreviousDigest *string `json:"previous_digest"`
	ValidUntilMS   int64   `json:"valid_until_ms"`
}
type RestoredShortfallRequest struct {
	Version   int                        `json:"version"`
	Epoch     int64                      `json:"epoch"`
	UntilMS   int64                      `json:"until_ms"`
	Admission Admission                  `json:"admission"`
	Selection ShortfallSelection         `json:"selection"`
	Authority RestoredShortfallAuthority `json:"authority"`
	Review    *RestoredShortfallReview   `json:"review,omitempty"`
}

/** 只承接恢复后的原请求；查询和执行不能夹带新的批准内容或金额。 */
func ReadRestoredShortfall(action string, raw []byte) (*RestoredShortfallRequest, error) {
	var q RestoredShortfallRequest
	if decodeResult(raw, &q) != nil || q.Version != 1 || q.Epoch <= q.Admission.AcceptedEpoch || q.UntilMS < 1 || !q.Selection.Valid() {
		return nil, ErrReference
	}
	original, _ := json.Marshal(q.Admission)
	if _, err := ReadAdmission(original); err != nil {
		return nil, ErrReference
	}
	if action == "original" {
		if q.Review != nil || q.Authority != (RestoredShortfallAuthority{}) {
			return nil, ErrReference
		}
		return &q, nil
	}
	if q.Authority.OriginalEpoch < q.Admission.AcceptedEpoch || q.Authority.OriginalEpoch > q.Epoch || q.Authority.Generation < 1 ||
		!digest.MatchString(q.Authority.ReviewDigest) || q.Authority.ReviewDigest == q.Selection.ApprovalDigest {
		return nil, ErrReference
	}
	switch action {
	case "approve":
		r := q.Review
		if r == nil || r.ValidUntilMS < 1 || (r.PreviousDigest == nil) != (q.Authority.Generation == 1) ||
			(r.PreviousDigest != nil && (!digest.MatchString(*r.PreviousDigest) || *r.PreviousDigest == q.Authority.ReviewDigest)) {
			return nil, ErrReference
		}
	case "apply", "resolution":
		if q.Review != nil {
			return nil, ErrReference
		}
	default:
		return nil, ErrReference
	}
	return &q, nil
}

// 只从原生认证结果构造，HTTP 正文不能提供任何身份或证明字段。
type RestoredShortfallAccess struct {
	KeyID     string    `json:"-"`
	CreatorID int64     `json:"-"`
	Revision  time.Time `json:"-"`
	Until     time.Time `json:"-"`
	Witness   string    `json:"-"`
}

/** 证明绑定动作、原请求、原命令及当前批准；数据库只看到核对值，不收到管理密钥。 */
func BindRestoredShortfallAccess(key, id string, creator int64, revision, until time.Time, action string, q *RestoredShortfallRequest) (RestoredShortfallAccess, bool) {
	var a RestoredShortfallAccess
	parts := strings.Split(key, "_")
	if q == nil || creator < 1 || revision.IsZero() || len(parts) != 4 || parts[0] != "adm" || parts[1] != "sc" || len(id) != 24 || parts[2] != id || !digest.MatchString(parts[3]) {
		return a, false
	}
	raw, _ := json.Marshal(q)
	if _, err := ReadRestoredShortfall(action, raw); err != nil {
		return a, false
	}
	until = time.UnixMilli(until.UnixMilli()).UTC()
	hashed := sha256.Sum256([]byte(key))
	review := q.Authority.ReviewDigest
	if action == "original" {
		review = q.Selection.ApprovalDigest
	}
	fields := []string{"meton.restored-shortfall.http.v1", hex.EncodeToString(hashed[:]), action, q.Admission.Origin.SourceRequestID, q.Selection.CommandID,
		strconv.FormatInt(int64(q.Authority.Generation), 10), review, strconv.FormatInt(until.UnixMilli(), 10)}
	witness := sha256.Sum256([]byte(strings.Join(fields, "|")))
	return RestoredShortfallAccess{KeyID: id, CreatorID: creator, Revision: revision, Until: until, Witness: hex.EncodeToString(witness[:])}, true
}

type RestoredShortfallEnvelope struct {
	Version int             `json:"version"`
	Action  string          `json:"action"`
	Epoch   int64           `json:"epoch"`
	Origin  metonfee.Origin `json:"origin"`
	Data    json.RawMessage `json:"data"`
}
