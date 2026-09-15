// Package api (middleware_jwt.go): the end-user/service-account JWT check
// for the auth/tenant/audit routes (T074, FR-030). Distinct from
// middleware_auth.go's RequireMTLS - mTLS establishes which PEER NODE is
// talking to this daemon (node-to-node trust, T058), while RequireJWT
// establishes which USER OR TENANT a request is acting as on top of that
// already-mTLS-secured channel. Both apply together on the routes this
// file protects: a request must arrive over a trusted mTLS connection AND
// carry a valid bearer token.
package api

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
)

// claimsContextKey is the gin.Context key RequireJWT stores the validated
// *auth.Claims under, so downstream handlers read the caller's identity
// (Subject, TenantID, Roles) without re-parsing the token.
const claimsContextKey = "llmctld.auth.claims"

// RequireJWT validates the request's "Authorization: Bearer <token>"
// header through decider.ValidateToken (internal/authz, T071) rather than
// calling auth.ValidateToken directly - routing every HTTP-level
// authentication attempt through the Decider means it produces a chained
// audit entry exactly like every other authZ/authN decision this daemon
// makes (FR-035/SC-024's "100% of decisions"), not merely the ones called
// from Go code within this process. The actor recorded for an attempt
// that FAILS validation is the caller's real remote address (a token that
// fails to validate cannot be trusted to name its own claimed subject);
// the resource recorded is the request path, so an audit reader can see
// which endpoint an authentication attempt targeted.
//
// Aborts with 401 on any failure: missing header, malformed header, or a
// token that fails validation (bad signature, expired, wrong algorithm -
// see jwt.go's doc comment for the full list ValidateToken already
// rejects). On success it stores the validated claims for handlers via
// ClaimsFromContext.
func RequireJWT(decider *authz.Decider) gin.HandlerFunc {
	return func(c *gin.Context) {
		header := c.GetHeader("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(header, prefix) {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing or malformed Authorization: Bearer <token> header"})
			return
		}
		tokenString := strings.TrimPrefix(header, prefix)

		claims, err := decider.ValidateToken(tokenString, c.ClientIP(), c.Request.URL.Path)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": err.Error()})
			return
		}

		c.Set(claimsContextKey, claims)
		c.Next()
	}
}

// ClaimsFromContext returns the *auth.Claims RequireJWT stored for this
// request, or nil if RequireJWT was never applied (a route registered
// without it) - callers that require an authenticated caller MUST check
// for nil rather than assume RequireJWT always ran first.
func ClaimsFromContext(c *gin.Context) *auth.Claims {
	v, ok := c.Get(claimsContextKey)
	if !ok {
		return nil
	}
	claims, ok := v.(*auth.Claims)
	if !ok {
		return nil
	}
	return claims
}
