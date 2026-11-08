//go:build meton_managed && dispatch_integration

package metonexecution

/** NewFixtureProfile 仅在隔离测试构建允许回环 HTTP，不能装入正式托管服务。 */
func NewFixtureProfile(s Spec) (*Profile, error) { return newProfile(s, true) }
