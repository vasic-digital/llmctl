// Package api (routes_audit.go): the audit-log query HTTP routes (T074,
// FR-035) - GET /v1/audit/entries (the full chained decision log) and
// GET /v1/audit/verify (Constitution §11.4.268's tamper-evidence check,
// exposed operationally) - backed by the real *audit.Log a *authz.Decider
// (T071) already writes every authZ/authN decision into. Both routes are
// admin/tenant-admin-only: the audit trail is an operator-facing
// capability, never self-service for an ordinary caller.
package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
)

// RegisterAuditRoutes wires the audit routes onto r, backed by decider's
// audit.Log.
func RegisterAuditRoutes(r gin.IRoutes, decider *authz.Decider) {
	requireAuditAccess := func(c *gin.Context) bool {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionTenantManage, "audit-log") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting tenant:manage"})
			return false
		}
		return true
	}

	r.GET("/v1/audit/entries", RequireJWT(decider), func(c *gin.Context) {
		if !requireAuditAccess(c) {
			return
		}
		c.JSON(http.StatusOK, gin.H{"entries": decider.Log.Entries()})
	})

	r.GET("/v1/audit/verify", RequireJWT(decider), func(c *gin.Context) {
		if !requireAuditAccess(c) {
			return
		}
		ok, brokenAt := decider.Log.VerifyChain()
		resp := gin.H{"ok": ok}
		if !ok {
			resp["broken_at"] = brokenAt
		}
		c.JSON(http.StatusOK, resp)
	})
}
