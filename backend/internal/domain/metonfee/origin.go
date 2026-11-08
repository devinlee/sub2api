package metonfee

/** Valid 保留原请求身份校验，受理查询与费用报告共用，不把当前 Key 或恢复代次拼入原身份。 */
func (o Origin) Valid() bool {
	return label.MatchString(o.Environment) && label.MatchString(o.Source) &&
		(o.Caller == "meton.chat.v1" || o.Caller == "meton.oc07.v1") &&
		validID(o.SourceMarker) && validID(o.User) && validID(o.Account) && validID(o.OperationID) && validID(o.SourceRequestID)
}
