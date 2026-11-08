package metonmodel

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/domain/metonfee"
)

const CorrectionRoute = "/meton/managed-accounts/:operation/model-calls/:caller/:request/correction/"

type CorrectionSelection struct {
	Decision       string `json:"decision"`
	CaseID         string `json:"case_id"`
	AttemptID      string `json:"attempt_id"`
	RulingVersion  int32  `json:"ruling_version"`
	Generation     int32  `json:"generation"`
	ApprovalDigest string `json:"approval_digest"`
}

type CorrectionLine struct {
	CreditEvent string `json:"credit_event"`
	Amount      string `json:"amount"`
}

type CorrectionReview struct {
	PreviousDigest *string          `json:"previous_digest"`
	Final          bool             `json:"final"`
	ValidUntilMS   int64            `json:"valid_until_ms"`
	Sources        []CorrectionLine `json:"sources"`
}

type CorrectionPageQuery struct {
	Limit  int                    `json:"limit"`
	Cursor *CorrectionBasisCursor `json:"cursor"`
}

type CorrectionBasisSnapshot struct {
	Origin        metonfee.Origin `json:"origin"`
	Item          string          `json:"item"`
	Basis         string          `json:"basis"`
	Epoch         int64           `json:"epoch"`
	Decision      *string         `json:"decision"`
	RulingVersion int32           `json:"ruling_version"`
	Applied       bool            `json:"applied"`
}

type CorrectionBasisCursor struct {
	Snapshot CorrectionBasisSnapshot `json:"snapshot"`
	After    string                  `json:"after"`
}

/** Matches 让 HTTP 和来源账本使用相同的分页归属及裁决版本。 */
func (s CorrectionBasisSnapshot) Matches(o metonfee.Origin, item, basis string, epoch int64) bool {
	if s.Origin != o || s.Item != item || s.Basis != basis || s.Epoch != epoch {
		return false
	}
	if s.Decision == nil {
		return s.RulingVersion == 0 && !s.Applied
	}
	return reconciliationID(*s.Decision) && s.RulingVersion > 0
}

// CorrectionRequest 每种路由只接受它的字段。原受理保持原代次；当前身份、恢复链与批准授权由服务和来源事务复验。
type CorrectionRequest struct {
	Version   int                  `json:"version"`
	Epoch     int64                `json:"epoch"`
	UntilMS   int64                `json:"until_ms"`
	Admission Admission            `json:"admission"`
	Item      string               `json:"item"`
	Basis     string               `json:"basis"`
	Page      *CorrectionPageQuery `json:"page,omitempty"`
	Selection *CorrectionSelection `json:"selection,omitempty"`
	Review    *CorrectionReview    `json:"review,omitempty"`
}

func ReadCorrection(action string, raw []byte) (*CorrectionRequest, error) {
	var q CorrectionRequest
	if decodeResult(raw, &q) != nil || q.Version != 1 || q.Epoch < 1 || q.UntilMS < 1 || q.Admission.AcceptedEpoch > q.Epoch ||
		!reconciliationID(q.Item) || !reconciliationID(q.Basis) {
		return nil, ErrReference
	}
	admission, _ := json.Marshal(q.Admission)
	if _, err := ReadAdmission(admission); err != nil {
		return nil, ErrReference
	}
	switch action {
	case "basis":
		if q.Page == nil || q.Page.Limit < 1 || q.Page.Limit > 64 || q.Selection != nil || q.Review != nil {
			return nil, ErrReference
		}
		if c := q.Page.Cursor; c != nil && (!reconciliationID(c.After) || !c.Snapshot.Matches(q.Admission.Origin, q.Item, q.Basis, q.Epoch)) {
			return nil, ErrReference
		}
		return &q, nil
	case "approve", "apply", "resolution":
	default:
		return nil, ErrReference
	}
	k := q.Selection
	if q.Page != nil || k == nil || !reconciliationID(k.Decision) || !reconciliationID(k.CaseID) || !reconciliationID(k.AttemptID) ||
		k.RulingVersion < 1 || k.Generation < 1 || !digest.MatchString(k.ApprovalDigest) {
		return nil, ErrReference
	}
	if action == "approve" {
		r := q.Review
		if r == nil || r.ValidUntilMS < 1 || (r.PreviousDigest == nil) != (k.Generation == 1) ||
			(r.PreviousDigest != nil && (!digest.MatchString(*r.PreviousDigest) || *r.PreviousDigest == k.ApprovalDigest)) ||
			len(r.Sources) < 1 || len(r.Sources) > 64 {
			return nil, ErrReference
		}
		seen := make(map[string]bool, len(r.Sources))
		for _, line := range r.Sources {
			if !reconciliationID(line.CreditEvent) || seen[line.CreditEvent] || !amount.MatchString(line.Amount) || line.Amount == "0.00000000" {
				return nil, ErrReference
			}
			seen[line.CreditEvent] = true
		}
	} else if q.Review != nil {
		return nil, ErrReference
	}
	return &q, nil
}

// CorrectionAccess 只在认证后的服务端内存和受限数据库参数中使用，不从 HTTP 正文反序列化。
type CorrectionAccess struct {
	KeyID     string    `json:"-"`
	CreatorID int64     `json:"-"`
	Revision  time.Time `json:"-"`
	Until     time.Time `json:"-"`
	Witness   string    `json:"-"`
}

/** BindCorrectionAccess 用原密钥在本机生成本动作的比对值，数据库只收到比对值和已认证行版本。 */
func BindCorrectionAccess(key, id string, creator int64, revision, until time.Time, action string, q *CorrectionRequest) (CorrectionAccess, bool) {
	var access CorrectionAccess
	parts := strings.Split(key, "_")
	if q == nil || creator <= 0 || revision.IsZero() || len(parts) != 4 || parts[0] != "adm" || parts[1] != "sc" ||
		len(id) != 24 || parts[2] != id || !digest.MatchString(parts[3]) {
		return access, false
	}
	decision, approval := "-", "-"
	if q.Selection != nil {
		decision, approval = q.Selection.Decision, q.Selection.ApprovalDigest
	}
	until = time.UnixMilli(until.UnixMilli()).UTC()
	keyHash := sha256.Sum256([]byte(key))
	fields := []string{"meton.correction.http.v1", hex.EncodeToString(keyHash[:]), action, q.Admission.Origin.SourceRequestID, q.Item, q.Basis,
		decision, approval, strconv.FormatInt(until.UnixMilli(), 10)}
	witness := sha256.Sum256([]byte(strings.Join(fields, "|")))
	return CorrectionAccess{KeyID: id, CreatorID: creator, Revision: revision, Until: until, Witness: hex.EncodeToString(witness[:])}, true
}

type CorrectionEnvelope struct {
	Version int             `json:"version"`
	Action  string          `json:"action"`
	Epoch   int64           `json:"epoch"`
	Origin  metonfee.Origin `json:"origin"`
	Data    json.RawMessage `json:"data"`
}
