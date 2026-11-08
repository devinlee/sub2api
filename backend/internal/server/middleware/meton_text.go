package middleware

import (
	"context"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/pkg/ctxkey"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

type MetonTextAdmitter interface {
	Admit(*http.Request) (*http.Request, *service.APIKey, error)
}

/** MetonTextAuth 沿原生处理器所需上下文接线；外部自填身份不参与用户或组的选择。 */
func MetonTextAuth(admission MetonTextAdmitter) gin.HandlerFunc {
	if !service.MetonManagedBuild || admission == nil {
		return nil
	}
	return func(c *gin.Context) {
		request, key, err := admission.Admit(c.Request)
		if err != nil || request == nil || key == nil || !service.MetonTextAdmitted(request.Context(), key) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"code": "METON_SOURCE_RESTRICTED"})
			return
		}
		c.Request = request.WithContext(context.WithValue(request.Context(), ctxkey.UserID, key.UserID))
		c.Set(string(ContextKeyAPIKey), key)
		c.Set(string(ContextKeyUser), AuthSubject{UserID: key.UserID, Concurrency: key.User.Concurrency})
		c.Set(string(ContextKeyUserRole), key.User.Role)
		setGroupContext(c, key.Group)
		c.Next()
	}
}
