package service

import (
	"encoding/json"
	"regexp"
	"strings"
)

var manualReviewText = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,120}$`)
var manualReviewFen = regexp.MustCompile(`^(0|[1-9][0-9]{0,38})$`)

/** 对原上下文逐字段封闭；将来新增材料或身份字段时，必须明确更新用途后才能对外提供。 */
func validManualValue(raw json.RawMessage, key string) bool {
	var v map[string]json.RawMessage
	if decodeStatement(raw, &v) != nil || v == nil {
		return false
	}
	p := strings.Split(key, "/")
	if len(p) != 2 {
		return false
	}
	fields := []string{"kind", "refund", "app", "order", "transaction", "verificationRevision", "verificationHash", "payerState", "channelState", "alreadyDecided"}
	if p[0] == "dispute" {
		fields = []string{"kind", "id", "app", "revision", "state", "cashHash", "cashExposure", "assigned", "finding", "financialState"}
	}
	if !manualFields(v, fields) || manualString(v["kind"]) != p[0] || !manualReviewText.MatchString(manualString(v["app"])) {
		return false
	}
	if p[0] == "refund" {
		var decided *bool
		if json.Unmarshal(v["alreadyDecided"], &decided) != nil || decided == nil || manualString(v["refund"]) != p[1] ||
			!manualReviewText.MatchString(manualString(v["order"])) || !manualReviewText.MatchString(manualString(v["transaction"])) {
			return false
		}
		var revision *int64
		if json.Unmarshal(v["verificationRevision"], &revision) != nil {
			return false
		}
		if revision == nil {
			return string(v["verificationHash"]) == "null" && string(v["payerState"]) == "null" && string(v["channelState"]) == "null"
		}
		return *revision > 0 && cashStatementDigest.MatchString(manualString(v["verificationHash"])) && manualReviewText.MatchString(manualString(v["payerState"])) && manualReviewText.MatchString(manualString(v["channelState"]))
	}
	var revision int64
	var assigned *bool
	if manualString(v["id"]) != p[1] || json.Unmarshal(v["revision"], &revision) != nil || revision <= 0 || json.Unmarshal(v["assigned"], &assigned) != nil || assigned == nil ||
		!cashStatementDigest.MatchString(manualString(v["cashHash"])) || manualString(v["financialState"]) != "restricted" {
		return false
	}
	switch manualString(v["state"]) {
	case "pending_review", "reviewing", "awaiting_material", "reviewed_restricted":
	default:
		return false
	}
	if string(v["finding"]) != "null" && !manualReviewText.MatchString(manualString(v["finding"])) {
		return false
	}
	return validManualExposure(v["cashExposure"])
}

/** 现金概要只允许原算法的计数、金额文字和摘要；没有任意嵌套报文或新增身份字段。 */
func validManualExposure(raw json.RawMessage) bool {
	var v map[string]json.RawMessage
	if decodeStatement(raw, &v) != nil || v == nil {
		return false
	}
	fields := []string{"format", "original", "currency", "externalEvents", "ambiguousExternalEvents", "ambiguousRefundEvents", "knownExternalFen", "knownRefundFen", "knownReturnedFen", "payerCapFen", "knownExcessFen", "evidenceHash", "alternativeEvents", "ambiguousAlternativeEvents", "knownAlternativeFen"}
	if !manualFields(v, fields) || string(v["format"]) != "2" || manualString(v["currency"]) != "CNY" || !cashStatementDigest.MatchString(manualString(v["original"])) || !cashStatementDigest.MatchString(manualString(v["evidenceHash"])) {
		return false
	}
	for _, name := range []string{"externalEvents", "ambiguousExternalEvents", "ambiguousRefundEvents", "alternativeEvents", "ambiguousAlternativeEvents"} {
		var n *int64
		if json.Unmarshal(v[name], &n) != nil || n == nil || *n < 0 {
			return false
		}
	}
	for _, name := range []string{"knownExternalFen", "knownRefundFen", "knownReturnedFen", "payerCapFen", "knownExcessFen", "knownAlternativeFen"} {
		if (name == "payerCapFen" || name == "knownExcessFen") && string(v[name]) == "null" {
			continue
		}
		if !manualReviewFen.MatchString(manualString(v[name])) {
			return false
		}
	}
	return true
}
func manualFields(v map[string]json.RawMessage, fields []string) bool {
	if len(v) != len(fields) {
		return false
	}
	for _, key := range fields {
		if _, ok := v[key]; !ok {
			return false
		}
	}
	return true
}
func manualString(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return ""
	}
	return s
}
