// Package api (routes_auth.go): the end-user/service-account auth HTTP
// routes (T074, FR-030/FR-032) - POST /v1/auth/token (API-key-for-JWT
// exchange, the bootstrap path so a caller can obtain its FIRST bearer
// token) and the JWT-protected API-key lifecycle
// (POST /v1/auth/apikeys, POST /v1/auth/apikeys/:id/rotate,
// DELETE /v1/auth/apikeys/:id) - backed by a real *auth.Store and routed
// through the audited *authz.Decider (T071) for every JWT validation.
package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	jwtlib "github.com/golang-jwt/jwt/v5"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
)

// issuedTokenTTL is how long a JWT issued via the token-exchange endpoint
// lives before a caller must exchange its API key again. This project's
// spec gives no specific figure for JWT lifetime (only the 5-minute OIDC
// fallback window, T068, which is a distinct mechanism), so one hour is a
// conservative, explicitly documented operational default rather than a
// silently invented one - short enough to bound a leaked token's blast
// radius, long enough that a caller is not forced to re-exchange on every
// request.
const issuedTokenTTL = time.Hour

// tenantScopePrefix marks an API key scope entry as encoding the tenant
// this key's issued JWTs should carry, e.g. "tenant:acme". Every OTHER
// scope entry becomes an RBAC role name on the issued token's Roles
// (rbac.go's Check evaluates them directly). This project's apikey.APIKey
// (T067) has no dedicated TenantID field - encoding it as a scope keeps
// Store's shape unchanged (T067's file scope was apikey.go/apikey_test.go
// only) while still letting a key deterministically carry tenant
// membership through to the JWTs it is exchanged for.
const tenantScopePrefix = "tenant:"

// requireKeyManagementAccess gates API-key creation, rotation, and
// revocation behind the SAME bar as tenant creation (routes_tenants.go's
// POST /v1/tenants) and audit-log access (routes_audit.go's
// requireAuditAccess): a role granting ActionTenantManage.
//
// This closes a genuine, critical privilege-escalation vulnerability
// found during T075's security review: before this check existed,
// POST /v1/auth/apikeys was gated by RequireJWT ONLY - ANY caller holding
// a merely-valid (but arbitrarily low-privileged, e.g. model-viewer) JWT
// could self-mint a BRAND NEW API key with Scopes=["admin"], then
// immediately exchange that key via POST /v1/auth/token for a fully
// admin-privileged JWT, completely bypassing RBAC (FR-031) - see
// TestCreateAPIKey_PrivilegeEscalation_NonAdminCannotSelfMintAdminKey's
// doc comment for the exact exploit this closes. API-key lifecycle
// management is therefore an admin-managed resource end-to-end, never
// self-service for an arbitrary authenticated caller.
func requireKeyManagementAccess(decider *authz.Decider, c *gin.Context) bool {
	claims := ClaimsFromContext(c)
	if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionTenantManage, "apikeys") {
		c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting tenant:manage"})
		return false
	}
	return true
}

func splitScopesIntoTenantAndRoles(scopes []string) (tenantID string, roles []string) {
	for _, scope := range scopes {
		if after, ok := strings.CutPrefix(scope, tenantScopePrefix); ok {
			tenantID = after
			continue
		}
		roles = append(roles, scope)
	}
	return tenantID, roles
}

type tokenExchangeRequest struct {
	APIKeyID     string `json:"api_key_id" binding:"required"`
	APIKeySecret string `json:"api_key_secret" binding:"required"`
}

type createAPIKeyRequest struct {
	OwnerID    string   `json:"owner_id" binding:"required"`
	Scopes     []string `json:"scopes"`
	TTLSeconds int64    `json:"ttl_seconds"`
}

// RegisterAuthRoutes wires the auth routes onto r, backed by decider (for
// JWT issuance/validation, audited per T071) and keys (the real API-key
// store, T067). POST /v1/auth/token is deliberately NOT behind RequireJWT
// - it is the one route a caller with no JWT yet must be able to reach.
func RegisterAuthRoutes(r gin.IRoutes, decider *authz.Decider, keys *auth.Store) {
	r.POST("/v1/auth/token", func(c *gin.Context) {
		var req tokenExchangeRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}

		// Routed through decider.CheckAPIKey (T071/T075), not keys.Validate
		// directly, so every authentication attempt against this endpoint -
		// success or failure, including brute-force guesses - produces a
		// chained audit entry exactly like every other authZ/authN decision
		// this daemon makes (FR-035/SC-024's "100% of decisions"). The actor
		// recorded is the caller-presented API key id, never the secret.
		key, err := decider.CheckAPIKey(keys, req.APIKeyID, req.APIKeySecret, req.APIKeyID, "/v1/auth/token")
		if err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"error": err.Error()})
			return
		}

		tenantID, roles := splitScopesIntoTenantAndRoles(key.Scopes)
		token, err := auth.IssueToken(auth.Claims{
			RegisteredClaims: jwtlib.RegisteredClaims{
				Subject:   key.OwnerID,
				ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(issuedTokenTTL)),
			},
			TenantID: tenantID,
			Roles:    roles,
		}, decider.SigningKey)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"token": token})
	})

	r.POST("/v1/auth/apikeys", RequireJWT(decider), func(c *gin.Context) {
		if !requireKeyManagementAccess(decider, c) {
			return
		}
		var req createAPIKeyRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		id, secret, err := keys.Create(req.OwnerID, req.Scopes, time.Duration(req.TTLSeconds)*time.Second)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"id": id, "secret": secret})
	})

	r.POST("/v1/auth/apikeys/:id/rotate", RequireJWT(decider), func(c *gin.Context) {
		if !requireKeyManagementAccess(decider, c) {
			return
		}
		secret, err := keys.Rotate(c.Param("id"))
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"secret": secret})
	})

	r.DELETE("/v1/auth/apikeys/:id", RequireJWT(decider), func(c *gin.Context) {
		if !requireKeyManagementAccess(decider, c) {
			return
		}
		if err := keys.Revoke(c.Param("id")); err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "revoked"})
	})
}
