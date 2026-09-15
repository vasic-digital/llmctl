// Package api (routes_models.go): the model-lifecycle dispatch routes
// (T072-FU4, FR-049/Clarification 18's "tenant model instances" phrase,
// closing internal/executor.LocalExecutor's last disclosed gap - T073's
// own evidence entry: "internal/executor.LocalExecutor ... was NOT
// constructed or called anywhere in cmd/llmctld or any other internal/
// package") - POST /v1/tenants/:id/models/:model/start, POST
// .../stop, GET .../status.
//
// These are the FIRST HTTP callers of internal/executor.LocalExecutor's
// real bin/llmctl subprocess dispatch. Every piece this file composes
// already existed, independently built and tested, before this file:
// auth.ActionModelStart/ActionModelStop/ActionModelView (rbac.go, T066 -
// defined in the predefinedRoles table but, before this file, consumed
// by no route anywhere); authorizeTenantOwnership + the
// RequireJWT/decider.CheckRBAC pattern (routes_tenants.go, T074/T075);
// decider.CheckTenantBoundary (authz/decide.go, T071 - the SAME audited
// tenant-visibility check GET .../visible already uses); and
// executor.LocalExecutor.WithTenant (T072-FU4's one small addition to
// internal/executor, needed because a single daemon process serves many
// tenants concurrently from one shared base executor, so tenant scoping
// cannot be a construction-time-only field).
//
// Every route requires, in this order (ALL must hold):
//  1. RequireJWT - a valid bearer token.
//  2. authorizeTenantOwnership(decider, claims, :id) - the caller may
//     act on behalf of tenant :id (its own tenant, or holds
//     ActionTenantManage). Composes with (3): a tenant-admin acting
//     within its OWN tenant does NOT thereby gain model-lifecycle
//     permissions - rbac.go's own doc comment: "tenant-admin is scoped
//     to tenant management ... a distinct concern, not a synonym for
//     elevated model-operator".
//  3. decider.CheckRBAC(..., action, :id) - the caller's role grants the
//     SPECIFIC action this route performs (ActionModelStart for
//     .../start, ActionModelStop for .../stop, ActionModelView - the
//     read-only action model-viewer already holds - for .../status).
//  4. decider.CheckTenantBoundary(..., :id, :model) - :model must be
//     VISIBLE to :id (registered by it via POST /v1/tenants/:id/models,
//     or shared with it) before this daemon dispatches a real
//     subprocess on the caller's behalf - a tenant can never
//     start/stop/query an arbitrary catalog profile name it never
//     registered.
//
// Dispatch is THIS NODE ONLY: base.WithTenant(:id) scopes a fresh
// executor per request to the resolved tenant, then calls
// Start/Stop/Status directly against THIS process's real bin/llmctl. No
// cross-node routing/scheduling exists anywhere in this codebase yet -
// the same disclosed per-node boundary T073/T075 already established
// for the tenancy/auth stack ("cmd/llmctld's newAuthzDecider constructs
// a fresh, independent, purely in-memory Registry/Store PER NODE with
// no cross-node forwarding daemon yet") - so an operator targets a
// specific node's API to act on that node's own model instances, exactly
// as every other route in this package already works.
package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/executor"
)

// authorizeModelAction resolves a request's claims/:id/:model and runs
// the full ownership + RBAC-action + tenant-visibility gate common to
// all three model-lifecycle routes, writing the appropriate 403 (and
// returning ok=false) at whichever check first fails. Callers proceed to
// dispatch only when ok is true.
func authorizeModelAction(c *gin.Context, decider *authz.Decider, action auth.Action) (claims *auth.Claims, tenantID, model string, ok bool) {
	claims = ClaimsFromContext(c)
	tenantID = c.Param("id")
	model = c.Param("model")

	if !authorizeTenantOwnership(decider, claims, tenantID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "caller may only operate on its own tenant's models"})
		return claims, tenantID, model, false
	}
	if !decider.CheckRBAC(claims.Subject, claims.Roles, action, tenantID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting " + string(action)})
		return claims, tenantID, model, false
	}
	if !decider.CheckTenantBoundary(claims.Subject, tenantID, model) {
		c.JSON(http.StatusForbidden, gin.H{"error": "model is not registered to or shared with this tenant"})
		return claims, tenantID, model, false
	}
	return claims, tenantID, model, true
}

// RegisterModelRoutes wires the model-lifecycle dispatch routes onto r,
// backed by decider (RBAC/tenant-visibility decisions) and base (the
// shared, tenant-less LocalExecutor every request scopes via
// base.WithTenant(tenantID) before dispatching - see this file's package
// doc comment for the full authorization + dispatch contract).
func RegisterModelRoutes(r gin.IRoutes, decider *authz.Decider, base *executor.LocalExecutor) {
	r.POST("/v1/tenants/:id/models/:model/start", RequireJWT(decider), func(c *gin.Context) {
		_, tenantID, model, ok := authorizeModelAction(c, decider, auth.ActionModelStart)
		if !ok {
			return
		}
		if err := base.WithTenant(tenantID).Start(model); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "started", "model": model})
	})

	r.POST("/v1/tenants/:id/models/:model/stop", RequireJWT(decider), func(c *gin.Context) {
		_, tenantID, model, ok := authorizeModelAction(c, decider, auth.ActionModelStop)
		if !ok {
			return
		}
		if err := base.WithTenant(tenantID).Stop(model); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "stopped", "model": model})
	})

	r.GET("/v1/tenants/:id/models/:model/status", RequireJWT(decider), func(c *gin.Context) {
		_, tenantID, model, ok := authorizeModelAction(c, decider, auth.ActionModelView)
		if !ok {
			return
		}
		status, err := base.WithTenant(tenantID).Status(model)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": status})
	})
}
