// Package api (routes_tenants.go): tenant CRUD + model-namespace
// isolation/sharing HTTP routes (T074, FR-033/FR-037) - backed by a real
// *tenancy.Registry and routed through the audited *authz.Decider (T071)
// for the RBAC and tenant-boundary decisions each handler makes.
package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
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
