// Package api (routes_tenants.go): tenant CRUD + model-namespace
// isolation/sharing HTTP routes (T074, FR-033/FR-037) - backed by a real
// *tenancy.Registry and routed through the audited *authz.Decider (T071)
// for the RBAC and tenant-boundary decisions each handler makes.
package api

import (
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

type createTenantRequest struct {
	ID   string `json:"id" binding:"required"`
	Name string `json:"name" binding:"required"`
}

type registerModelRequest struct {
	ModelName string `json:"model_name" binding:"required"`
}

type shareModelRequest struct {
	WithTenantID string `json:"with_tenant_id" binding:"required"`
}

// authorizeTenantOwnership reports whether the caller identified by claims
// may act on behalf of tenantID: either claims.TenantID matches it
// exactly, or the caller holds a role granting ActionTenantManage
// (admin/tenant-admin acting across tenant boundaries by design). Any
// caller failing both is denied - a tenant may only manage its OWN
// namespace unless explicitly elevated.
func authorizeTenantOwnership(d *authz.Decider, claims *auth.Claims, tenantID string) bool {
	if claims.TenantID == tenantID {
		return true
	}
	return d.CheckRBAC(claims.Subject, claims.Roles, auth.ActionTenantManage, tenantID)
}

// RegisterTenantRoutes wires the tenant routes onto r, backed by decider.
// Every route requires a valid JWT (RequireJWT); tenant creation
// additionally requires ActionTenantManage (admin/tenant-admin); model
// registration/sharing/listing require the caller to own the target
// tenant namespace or hold ActionTenantManage (authorizeTenantOwnership).
func RegisterTenantRoutes(r gin.IRoutes, decider *authz.Decider) {
	r.POST("/v1/tenants", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionTenantManage, "tenants") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting tenant:manage"})
			return
		}
		var req createTenantRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		tenant, err := decider.Tenants.Create(req.ID, req.Name)
		if err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"id": tenant.ID, "name": tenant.Name})
	})

	// GET /v1/tenants (006-cli-daemon-wiring FR-006, T013): lists every
	// tenant currently registered anywhere in the cluster. Gated behind
	// the SAME ActionTenantManage bar as POST /v1/tenants above, rather
	// than authorizeTenantOwnership (which only proves the caller may
	// act on ONE named tenant) - enumerating every tenant's id/name is a
	// cluster-wide admin view, exactly like tenant creation, and an
	// ordinary tenant-scoped caller has no legitimate need to see every
	// other tenant that exists (this file's own history, see
	// TestCheckModelVisible_CrossTenantQueryDenied above, is a real
	// cross-tenant information-disclosure vulnerability found in a
	// route that skipped this kind of check).
	r.GET("/v1/tenants", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionTenantManage, "tenants") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting tenant:manage"})
			return
		}
		tenants := decider.Tenants.List()
		out := make([]gin.H, 0, len(tenants))
		for _, t := range tenants {
			out = append(out, gin.H{"id": t.ID, "name": t.Name})
		}
		c.JSON(http.StatusOK, gin.H{"tenants": out})
	})

	// GET /v1/tenants/:id/quota (006-cli-daemon-wiring FR-007, T015):
	// views tenantID's currently-enforced Limits, sourced directly from
	// decider.Quota.GetLimits (T005) - the SAME Enforcer state
	// decider.CheckQuota/AllowRequest applies to that tenant's real
	// traffic, never a separately-tracked copy that could drift.
	// Existence is resolved against decider.Tenants.Get, NOT
	// decider.Quota, per data-model.md: a quota view is meaningless for
	// an unregistered tenant id, so a nonexistent tenant reports 404
	// rather than a default/zero Limits body that could be mistaken for
	// a real, intentional all-unlimited quota (spec.md's Edge Cases).
	r.GET("/v1/tenants/:id/quota", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		tenantID := c.Param("id")
		if !authorizeTenantOwnership(decider, claims, tenantID) {
			c.JSON(http.StatusForbidden, gin.H{"error": "caller may only view its own tenant's quota"})
			return
		}
		if _, ok := decider.Tenants.Get(tenantID); !ok {
			c.JSON(http.StatusNotFound, gin.H{"error": fmt.Sprintf("tenant %q not found", tenantID)})
			return
		}
		limits, _ := decider.Quota.GetLimits(tenantID)
		c.JSON(http.StatusOK, limits)
	})

	// PUT /v1/tenants/:id/quota (006-cli-daemon-wiring FR-007, T015; SECURITY
	// FIX post-review): the "set" half of tenant quota <name> [...]. Any
	// field omitted from the request body defaults to 0 (unlimited) per
	// Go's JSON-unmarshal zero-value behavior and Limits's own existing
	// zero-means-unlimited convention - no new "partial update" semantics
	// invented (data-model.md). Echoes the now-current Limits back on
	// success, same shape as the GET above; 404 check reused from GET.
	//
	// AUTHORIZATION IS THE SAME ActionTenantManage BAR AS POST
	// /v1/tenants, DELIBERATELY NOT authorizeTenantOwnership: an earlier
	// version of this handler used authorizeTenantOwnership (matching
	// the VIEW route below), which grants access whenever
	// claims.TenantID == the path tenant - letting a tenant's own,
	// otherwise-unprivileged JWT set its OWN enforced quota to anything
	// (including unlimited on every dimension), a genuine privilege
	// escalation that defeats the entire purpose of operator-imposed
	// quota enforcement (found by an automated commit security review;
	// TestSetTenantQuota_RequiresAdminRole is this vulnerability's
	// RED-before-GREEN proof, the SAME class of self-service-privilege-
	// escalation bug requireKeyManagementAccess in routes_auth.go was
	// already written to prevent for API-key creation). SETTING a quota
	// is an operator/admin action exactly like tenant creation, never a
	// tenant's own prerogative - VIEWING (the GET route immediately
	// above) is unaffected and stays ownership-gated.
	r.PUT("/v1/tenants/:id/quota", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		tenantID := c.Param("id")
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionTenantManage, "tenants") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting tenant:manage"})
			return
		}
		if _, ok := decider.Tenants.Get(tenantID); !ok {
			c.JSON(http.StatusNotFound, gin.H{"error": fmt.Sprintf("tenant %q not found", tenantID)})
			return
		}
		var limits tenancy.Limits
		if err := c.ShouldBindJSON(&limits); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		decider.Quota.SetLimits(tenantID, limits)
		c.JSON(http.StatusOK, limits)
	})

	r.GET("/v1/tenants/:id/models", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		tenantID := c.Param("id")
		if !authorizeTenantOwnership(decider, claims, tenantID) {
			c.JSON(http.StatusForbidden, gin.H{"error": "caller may only list its own tenant's models"})
			return
		}
		models := decider.Tenants.ListVisibleModels(tenantID)
		if models == nil {
			models = []string{}
		}
		c.JSON(http.StatusOK, gin.H{"models": models})
	})

	r.POST("/v1/tenants/:id/models", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		tenantID := c.Param("id")
		if !authorizeTenantOwnership(decider, claims, tenantID) {
			c.JSON(http.StatusForbidden, gin.H{"error": "caller may only register models into its own tenant's namespace"})
			return
		}
		var req registerModelRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		if err := decider.Tenants.RegisterModel(tenantID, req.ModelName); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "registered"})
	})

	r.POST("/v1/tenants/:id/models/:model/share", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		ownerTenantID := c.Param("id")
		if !authorizeTenantOwnership(decider, claims, ownerTenantID) {
			c.JSON(http.StatusForbidden, gin.H{"error": "caller may only share models it owns"})
			return
		}
		var req shareModelRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		if err := decider.Tenants.ShareModel(ownerTenantID, c.Param("model"), req.WithTenantID); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "shared"})
	})

	r.GET("/v1/tenants/:id/models/:model/visible", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		tenantID := c.Param("id")
		// authorizeTenantOwnership gate added per T075's security review:
		// without it, ANY authenticated caller (any tenant, any role) could
		// query ANY other tenant's model-visibility oracle directly via
		// this path parameter, enumerating another tenant's registered/
		// shared model catalog one guessed name at a time - a genuine
		// cross-tenant information-disclosure vulnerability that directly
		// violated US9 Acceptance Scenario 1 / SC-022 ("zero cross-tenant
		// data leakage"). This mirrors the SAME check its sibling routes
		// (GET/POST /v1/tenants/:id/models) already correctly apply.
		if !authorizeTenantOwnership(decider, claims, tenantID) {
			c.JSON(http.StatusForbidden, gin.H{"error": "caller may only check visibility within its own tenant's namespace"})
			return
		}
		visible := decider.CheckTenantBoundary(claims.Subject, tenantID, c.Param("model"))
		c.JSON(http.StatusOK, gin.H{"visible": visible})
	})
}
