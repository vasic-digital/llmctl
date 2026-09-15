// Package authz wires the tamper-evident audit log (internal/audit,
// Phase 2's T013, extended in Phase 11 with Constitution §11.4.268's
// anchor mechanism) into every authZ/authN decision path this daemon
// makes: JWT validation, RBAC checks, quota enforcement, and tenant-
// boundary checks (FR-035, SC-024, T071). Decider composes the
// already-implemented pure decision functions in internal/auth and
// internal/tenancy - it never reimplements their logic, only wraps each
// call with an audit.Log.Append so 100% of decisions, allow or deny,
// leave a chained record.
package authz

import (
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

const (
	decisionAllow = "allow"
	decisionDeny  = "deny"
)

// Decider is the single audited entry point for this daemon's four
// authZ/authN decision classes. Its fields are the already-tested,
// independent packages it composes (internal/audit's chained Log,
// internal/auth's token/role machinery, internal/tenancy's quota/tenant
// machinery) - Decider adds nothing to their decision logic, only the
// audit-logging wrapper around each call.
type Decider struct {
	Log        *audit.Log
	SigningKey []byte
	RBAC       *auth.RoleRegistry
	Quota      *tenancy.Enforcer
	Tenants    *tenancy.Registry
}

// NewDecider returns a Decider composing the given already-constructed
// components. Callers own the lifetime of each component (e.g. one
// Enforcer/Registry per running daemon) - Decider does not construct or
// own them itself.
func NewDecider(log *audit.Log, signingKey []byte, rbac *auth.RoleRegistry, quota *tenancy.Enforcer, tenants *tenancy.Registry) *Decider {
	return &Decider{Log: log, SigningKey: signingKey, RBAC: rbac, Quota: quota, Tenants: tenants}
}

// ValidateToken wraps auth.ValidateToken, logging the outcome under actor
// (the token's claimed subject at call time, since a REJECTED token's own
// claims cannot be trusted as the actor) against resource. Both a
// successful validation and a rejection produce exactly one audit entry -
// an audit log that only recorded successes would hide the unauthorized-
// access attempts it exists to catch.
func (d *Decider) ValidateToken(tokenString, actor, resource string) (*auth.Claims, error) {
	claims, err := auth.ValidateToken(tokenString, d.SigningKey)
	decision := decisionAllow
	if err != nil {
		decision = decisionDeny
	}
	d.Log.Append(actor, "jwt_validate", resource, decision)
	return claims, err
}

// CheckRBAC wraps d.RBAC.Check, logging the outcome under actor against
// resource.
func (d *Decider) CheckRBAC(actor string, roles []string, action auth.Action, resource string) bool {
	allowed := d.RBAC.Check(roles, action)
	decision := decisionDeny
	if allowed {
		decision = decisionAllow
	}
	d.Log.Append(actor, "rbac_check", resource, decision)
	return allowed
}

// CheckQuota wraps d.Quota.AllowRequest, logging the outcome under actor
// against tenantID (the resource this decision is scoped to).
func (d *Decider) CheckQuota(actor, tenantID string, now time.Time) (allowed bool, retryAfter time.Duration) {
	allowed, retryAfter = d.Quota.AllowRequest(tenantID, now)
	decision := decisionDeny
	if allowed {
		decision = decisionAllow
	}
	d.Log.Append(actor, "quota_check", tenantID, decision)
	return allowed, retryAfter
}

// CheckAPIKey wraps keys.Validate, logging the outcome under actor (the
// caller-presented API key id - a rejected attempt's claimed owner cannot
// be trusted, so the id itself, never the secret, is what identifies the
// attempt for audit purposes, exactly like ValidateToken uses the caller's
// address rather than a rejected token's own claims) against resource.
//
// Added per T075's security review: POST /v1/auth/token
// (internal/api/routes_auth.go) previously called an *auth.Store's
// Validate directly, bypassing this Decider entirely, so EVERY
// authentication attempt against the API-key-exchange endpoint - success
// or failure, including brute-force guesses - was invisible to the audit
// log, violating FR-035/SC-024's "100% of authZ/authN decisions logged".
// keys is passed per call (rather than stored as a Decider field) so this
// addition does not change NewDecider's constructor signature for any
// existing caller - every call site already holds its own *auth.Store
// (T067's file-scope boundary keeps Store construction outside this
// package).
func (d *Decider) CheckAPIKey(keys *auth.Store, apiKeyID, apiKeySecret, actor, resource string) (*auth.APIKey, error) {
	key, err := keys.Validate(apiKeyID, apiKeySecret)
	decision := decisionAllow
	if err != nil {
		decision = decisionDeny
	}
	d.Log.Append(actor, "apikey_validate", resource, decision)
	return key, err
}

// CheckTenantBoundary wraps d.Tenants.IsVisible, logging the outcome under
// actor against modelName - the tenant-boundary check US9 Acceptance
// Scenario 1 requires be audited exactly like every other authZ decision.
func (d *Decider) CheckTenantBoundary(actor, tenantID, modelName string) bool {
	visible := d.Tenants.IsVisible(tenantID, modelName)
	decision := decisionDeny
	if visible {
		decision = decisionAllow
	}
	d.Log.Append(actor, "tenant_boundary_check", modelName, decision)
	return visible
}
