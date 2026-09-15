package authz

import (
	"testing"
	"time"

	jwtlib "github.com/golang-jwt/jwt/v5"

	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

func issueTestToken(t *testing.T, signingKey []byte, expiresAt time.Time) string {
	t.Helper()
	token, err := auth.IssueToken(auth.Claims{
		RegisteredClaims: jwtlib.RegisteredClaims{ExpiresAt: jwtlib.NewNumericDate(expiresAt)},
	}, signingKey)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	return token
}

func newTestDecider(t *testing.T) (*Decider, []byte) {
	t.Helper()
	signingKey := []byte("test-signing-key-32-bytes-long!!")
	log := audit.NewLog()
	rbac := auth.NewRoleRegistry()
	quota := tenancy.NewEnforcer()
	tenants := tenancy.NewRegistry()
	if _, err := tenants.Create("tenant-a", "Tenant A"); err != nil {
		t.Fatalf("create tenant-a: %v", err)
	}
	if err := tenants.RegisterModel("tenant-a", "llama-7b"); err != nil {
		t.Fatalf("register model: %v", err)
	}
	return NewDecider(log, signingKey, rbac, quota, tenants), signingKey
}

// TestValidateToken_LogsAllowAndDeny proves T071's requirement for the
// JWT-validate decision path: BOTH an allow and a deny produce a chained
// audit entry - a system that only logs successes would hide exactly the
// unauthorized-access attempts an audit log exists to catch.
func TestValidateToken_LogsAllowAndDeny(t *testing.T) {
	d, signingKey := newTestDecider(t)

	validToken := issueTestToken(t, signingKey, time.Now().Add(time.Hour))

	if _, err := d.ValidateToken(validToken, "user-1", "cluster-api"); err != nil {
		t.Fatalf("expected valid token to validate, got error: %v", err)
	}
	if _, err := d.ValidateToken("not-a-real-token", "user-2", "cluster-api"); err == nil {
		t.Fatal("expected invalid token to fail validation")
	}

	entries := d.Log.Entries()
	if len(entries) != 2 {
		t.Fatalf("expected 2 audit entries, got %d", len(entries))
	}
	if entries[0].Decision != "allow" || entries[0].Actor != "user-1" || entries[0].Action != "jwt_validate" {
		t.Fatalf("entry 0 = %+v, want allow decision for user-1/jwt_validate", entries[0])
	}
	if entries[1].Decision != "deny" || entries[1].Actor != "user-2" || entries[1].Action != "jwt_validate" {
		t.Fatalf("entry 1 = %+v, want deny decision for user-2/jwt_validate", entries[1])
	}
}

// TestCheckRBAC_LogsAllowAndDeny proves the RBAC-check decision path is
// audited on both grant and refusal (US9 Acceptance Scenario 4's
// model-operator-can-delete / model-viewer-cannot distinction, now with an
// audit trail attached to each outcome).
func TestCheckRBAC_LogsAllowAndDeny(t *testing.T) {
	d, _ := newTestDecider(t)

	if allowed := d.CheckRBAC("operator-1", []string{auth.RoleModelOperator}, auth.ActionModelDelete, "llama-7b"); !allowed {
		t.Fatal("expected model-operator to be allowed to delete a model")
	}
	if allowed := d.CheckRBAC("viewer-1", []string{auth.RoleModelViewer}, auth.ActionModelDelete, "llama-7b"); allowed {
		t.Fatal("expected model-viewer to be denied deleting a model")
	}

	entries := d.Log.Entries()
	if len(entries) != 2 {
		t.Fatalf("expected 2 audit entries, got %d", len(entries))
	}
	if entries[0].Decision != "allow" || entries[0].Action != "rbac_check" {
		t.Fatalf("entry 0 = %+v, want allow/rbac_check", entries[0])
	}
	if entries[1].Decision != "deny" || entries[1].Action != "rbac_check" {
		t.Fatalf("entry 1 = %+v, want deny/rbac_check", entries[1])
	}
}

// TestCheckQuota_LogsAllowAndDeny proves the quota-check decision path is
// audited on both allow and 429-triggering denial (SC-023).
func TestCheckQuota_LogsAllowAndDeny(t *testing.T) {
	d, _ := newTestDecider(t)
	d.Quota.SetLimits("tenant-a", tenancy.Limits{RequestsPerSecond: 1})

	now := time.Now()
	if allowed, _ := d.CheckQuota("user-1", "tenant-a", now); !allowed {
		t.Fatal("expected first request within the rate limit to be allowed")
	}
	allowed, retryAfter := d.CheckQuota("user-1", "tenant-a", now)
	if allowed {
		t.Fatal("expected second immediate request to exceed the rate limit")
	}
	if retryAfter <= 0 {
		t.Fatalf("expected a positive Retry-After, got %v", retryAfter)
	}

	entries := d.Log.Entries()
	if len(entries) != 2 {
		t.Fatalf("expected 2 audit entries, got %d", len(entries))
	}
	if entries[0].Decision != "allow" || entries[0].Action != "quota_check" {
		t.Fatalf("entry 0 = %+v, want allow/quota_check", entries[0])
	}
	if entries[1].Decision != "deny" || entries[1].Action != "quota_check" {
		t.Fatalf("entry 1 = %+v, want deny/quota_check", entries[1])
	}
}

// TestCheckTenantBoundary_LogsAllowAndDeny proves the tenant-boundary-check
// decision path is audited on both a within-tenant view and a cross-tenant
// refusal (US9 Acceptance Scenario 1).
func TestCheckTenantBoundary_LogsAllowAndDeny(t *testing.T) {
	d, _ := newTestDecider(t)
	if _, err := d.Tenants.Create("tenant-b", "Tenant B"); err != nil {
		t.Fatalf("create tenant-b: %v", err)
	}

	if visible := d.CheckTenantBoundary("user-1", "tenant-a", "llama-7b"); !visible {
		t.Fatal("expected tenant-a to see its own registered model")
	}
	if visible := d.CheckTenantBoundary("user-2", "tenant-b", "llama-7b"); visible {
		t.Fatal("expected tenant-b to NOT see tenant-a's unshared model")
	}

	entries := d.Log.Entries()
	if len(entries) != 2 {
		t.Fatalf("expected 2 audit entries, got %d", len(entries))
	}
	if entries[0].Decision != "allow" || entries[0].Action != "tenant_boundary_check" {
		t.Fatalf("entry 0 = %+v, want allow/tenant_boundary_check", entries[0])
	}
	if entries[1].Decision != "deny" || entries[1].Action != "tenant_boundary_check" {
		t.Fatalf("entry 1 = %+v, want deny/tenant_boundary_check", entries[1])
	}
}

// TestAllDecisionPaths_ProduceAValidChain drives all four decision paths
// (8 decisions total: one allow + one deny each) through a single shared
// Decider and asserts FR-035/SC-024's literal requirement - 100% of
// authZ/authN decisions produce a chained entry - by checking the
// resulting log's entry count matches exactly and the whole chain still
// verifies (audit.Log.VerifyChain), proving the shared log was never
// bypassed by any of the four wrapped check functions.
func TestAllDecisionPaths_ProduceAValidChain(t *testing.T) {
	d, signingKey := newTestDecider(t)
	if _, err := d.Tenants.Create("tenant-b", "Tenant B"); err != nil {
		t.Fatalf("create tenant-b: %v", err)
	}
	d.Quota.SetLimits("tenant-a", tenancy.Limits{RequestsPerSecond: 1})

	validToken := issueTestToken(t, signingKey, time.Now().Add(time.Hour))

	_, _ = d.ValidateToken(validToken, "user-1", "cluster-api")
	_, _ = d.ValidateToken("garbage", "user-1", "cluster-api")
	d.CheckRBAC("user-1", []string{auth.RoleModelOperator}, auth.ActionModelDelete, "llama-7b")
	d.CheckRBAC("user-1", []string{auth.RoleModelViewer}, auth.ActionModelDelete, "llama-7b")
	now := time.Now()
	d.CheckQuota("user-1", "tenant-a", now)
	d.CheckQuota("user-1", "tenant-a", now)
	d.CheckTenantBoundary("user-1", "tenant-a", "llama-7b")
	d.CheckTenantBoundary("user-1", "tenant-b", "llama-7b")

	entries := d.Log.Entries()
	if len(entries) != 8 {
		t.Fatalf("expected exactly 8 audit entries (one per decision made), got %d", len(entries))
	}
	if ok, brokenAt := d.Log.VerifyChain(); !ok {
		t.Fatalf("expected the hash chain to verify cleanly across all 8 cross-path decisions, broke at index %d", brokenAt)
	}
}

// TestCheckAPIKey_LogsAllowAndDeny is T075's RED-before-GREEN proof for an
// audit-log coverage gap found during this security review: the
// POST /v1/auth/token HTTP handler (internal/api/routes_auth.go) called
// keys.Validate directly, NEVER through the audited *authz.Decider - so
// EVERY authentication attempt against the API-key-exchange endpoint
// (including brute-force guesses of an api_key_id/api_key_secret pair)
// was completely invisible to the audit log, violating FR-035's "System
// MUST audit log all authZ/authN decisions" and SC-024's literal "100% of
// authZ/authN decisions logged" - API-key validation IS an authN decision,
// exactly like JWT validation (which IS already audited via
// Decider.ValidateToken). This proves CheckAPIKey logs BOTH a successful
// and a failed validation attempt, mirroring TestValidateToken_LogsAllowAndDeny's
// shape for the JWT decision path.
func TestCheckAPIKey_LogsAllowAndDeny(t *testing.T) {
	d, _ := newTestDecider(t)
	keys := auth.NewKeyStore()
	id, secret, err := keys.Create("owner-1", nil, 0)
	if err != nil {
		t.Fatalf("create key: %v", err)
	}

	if _, err := d.CheckAPIKey(keys, id, secret, id, "/v1/auth/token"); err != nil {
		t.Fatalf("expected the real key+secret to validate, got error: %v", err)
	}
	if _, err := d.CheckAPIKey(keys, id, "wrong-secret", id, "/v1/auth/token"); err == nil {
		t.Fatal("expected an incorrect secret to fail validation")
	}

	entries := d.Log.Entries()
	if len(entries) != 2 {
		t.Fatalf("expected 2 audit entries, got %d", len(entries))
	}
	if entries[0].Decision != "allow" || entries[0].Action != "apikey_validate" || entries[0].Actor != id {
		t.Fatalf("entry 0 = %+v, want allow/apikey_validate for actor %q", entries[0], id)
	}
	if entries[1].Decision != "deny" || entries[1].Action != "apikey_validate" || entries[1].Actor != id {
		t.Fatalf("entry 1 = %+v, want deny/apikey_validate for actor %q", entries[1], id)
	}
}
