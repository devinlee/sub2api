package service

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

/** 人员资格由 Meton 现有权威复验；原材料摘要属于固定意图，结果查询不重新携带材料正文。 */
type CashManualReviewCommand struct {
	Format        int             `json:"format"`
	Operation     uuid.UUID       `json:"operation"`
	OriginalKey   string          `json:"originalKey"`
	BasisDigest   string          `json:"basisDigest"`
	ReviewKind    string          `json:"reviewKind"`
	Facts         json.RawMessage `json:"facts"`
	Person        uuid.UUID       `json:"person"`
	PersonVersion int64           `json:"personVersion"`
	Role          string          `json:"role"`
	IntentDigest  string          `json:"intentDigest"`
	Until         time.Time       `json:"until"`
}

/** 不能用金额、会员身份或任意用途代替人工核验；同一原键只接其既有审核种类。 */
func (q CashManualReviewCommand) Valid() bool {
	parts := strings.Split(q.OriginalKey, "/")
	if len(parts) != 2 || (parts[0] != "refund" && parts[0] != "dispute") || q.Format != 1 || q.Operation == uuid.Nil ||
		q.Person == uuid.Nil || q.PersonVersion <= 0 || q.PersonVersion > 999999999999999999 || q.Role != "reviewer" ||
		!cashStatementDigest.MatchString(q.BasisDigest) || !cashStatementDigest.MatchString(q.IntentDigest) ||
		!q.Until.After(time.Now()) || q.Until.After(time.Now().Add(30*time.Second)) || len(q.Facts) == 0 || len(q.Facts) > 8192 {
		return false
	}
	id, err := uuid.Parse(parts[1])
	if err != nil || id == uuid.Nil || id.String() != parts[1] ||
		(q.ReviewKind != "payer" && q.ReviewKind != "alternative" && q.ReviewKind != "dispute") || (q.ReviewKind == "dispute") != (parts[0] == "dispute") {
		return false
	}
	var fields map[string]json.RawMessage
	var hash string
	return json.Unmarshal(q.Facts, &fields) == nil && fields != nil && json.Unmarshal(fields["materialHash"], &hash) == nil && cashStatementDigest.MatchString(hash)
}
