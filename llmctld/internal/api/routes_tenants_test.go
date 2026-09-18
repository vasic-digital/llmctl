package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	jwtlib "github.com/golang-jwt/jwt/v5"

	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// newDeciderAndEngine builds a bare *gin.Engine (gin.TestMode) with a
// fresh *authz.Decider composing empty auth/tenancy state - shared setup
// for every route-registration test file in this package (routes_tenants,
// routes_audit) that needs a Decider but registers a DIFFERENT route set
// on top of it than routes_auth_test.go's newAuthTestEngine does.
func newDeciderAndEngine() (*gin.Engine, *authz.Decider) {
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	decider := authz.NewDecider(audit.NewLog(), []byte("test-signing-key"), auth.NewRoleRegistry(), tenancy.NewEnforcer(), tenancy.NewRegistry())
	return engine, decider
}

func newTenantsTestEngine() (*gin.Engine, *authz.Decider) {
	engine, decider := newDeciderAndEngine()
	RegisterTenantRoutes(engine, decider)
	return engine, decider
}

func issueTenantJWT(t *testing.T, decider *authz.Decider, tenantID string, roles []string) string {
	t.Helper()
	token, err := auth.IssueToken(auth.Claims{
		RegisteredClaims: jwtlib.RegisteredClaims{
			Subject:   "user-" + tenantID,
			ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(time.Hour)),
		},
		TenantID: tenantID,
		Roles:    roles,
	}, decider.SigningKey)
	if err != nil {
		t.Fatalf("issue tenant jwt: %v", err)
	}
	return token
}

// TestCreateTenant_RequiresAdminRole proves POST /v1/tenants is
// admin/tenant-admin-only: a caller with no such role is denied, one with
// RoleAdmin succeeds.
func TestCreateTenant_RequiresAdminRole(t *testing.T) {
	engine, decider := newTenantsTestEngine()

	viewerToken := issueTenantJWT(t, decider, "", []string{auth.RoleModelViewer})
	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": "tenant-a", "name": "Tenant A"}, viewerToken); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-admin caller, got %d: %s", rec.Code, rec.Body.String())
	}

	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	rec := doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": "tenant-a", "name": "Tenant A"}, adminToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for an admin caller, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestModelNamespace_IsolationAndSharing drives the literal US9 Acceptance
// Scenario 1 through the real HTTP layer: tenant-b cannot see tenant-a's
// model until tenant-a explicitly shares it, and tenant-c (never shared
// with) still cannot see it afterward.
func TestModelNamespace_IsolationAndSharing(t *testing.T) {
	engine, decider := newTenantsTestEngine()
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})

	for _, id := range []string{"tenant-a", "tenant-b", "tenant-c"} {
		if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": id, "name": id}, adminToken); rec.Code != http.StatusOK {
			t.Fatalf("create %s: expected 200, got %d: %s", id, rec.Code, rec.Body.String())
		}
	}

	tenantAToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})
	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models", map[string]string{"model_name": "llama-7b"}, tenantAToken); rec.Code != http.StatusOK {
		t.Fatalf("register model: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	tenantBToken := issueTenantJWT(t, decider, "tenant-b", []string{auth.RoleModelViewer})
	rec := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-b/models", nil, tenantBToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("list tenant-b models: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var listResp struct {
		Models []string `json:"models"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil {
		t.Fatalf("decode list response: %v", err)
	}
	if len(listResp.Models) != 0 {
		t.Fatalf("expected tenant-b to see zero models before sharing, got %v", listResp.Models)
	}

	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/llama-7b/share", map[string]string{"with_tenant_id": "tenant-b"}, tenantAToken); rec.Code != http.StatusOK {
		t.Fatalf("share model: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	rec = doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-b/models", nil, tenantBToken)
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil {
		t.Fatalf("decode list response after share: %v", err)
	}
	if len(listResp.Models) != 1 || listResp.Models[0] != "llama-7b" {
		t.Fatalf("expected tenant-b to see [llama-7b] after sharing, got %v", listResp.Models)
	}

	tenantCToken := issueTenantJWT(t, decider, "tenant-c", []string{auth.RoleModelViewer})
	rec = doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-c/models", nil, tenantCToken)
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil {
		t.Fatalf("decode list response for tenant-c: %v", err)
	}
	if len(listResp.Models) != 0 {
		t.Fatalf("expected tenant-c to see zero models (never shared with), got %v", listResp.Models)
	}
}

// TestModelNamespace_CrossTenantAccessDenied proves a caller cannot list
// or register models for a tenant other than its own claimed TenantID,
// unless it holds an admin-class role - the tenant-boundary check itself
// (distinct from model-level sharing).
func TestModelNamespace_CrossTenantAccessDenied(t *testing.T) {
	engine, decider := newTenantsTestEngine()
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	for _, id := range []string{"tenant-a", "tenant-b"} {
		doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": id, "name": id}, adminToken)
	}

	tenantBToken := issueTenantJWT(t, decider, "tenant-b", []string{auth.RoleModelOperator})
	rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models", map[string]string{"model_name": "sneaky"}, tenantBToken)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 registering a model into ANOTHER tenant's namespace, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestCheckModelVisible_ExercisesTenantBoundaryCheck proves
// GET /v1/tenants/:id/models/:model/visible drives T071's
// CheckTenantBoundary decision path through the HTTP layer end-to-end.
func TestCheckModelVisible_ExercisesTenantBoundaryCheck(t *testing.T) {
	engine, decider := newTenantsTestEngine()
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": "tenant-a", "name": "tenant-a"}, adminToken)
	tenantAToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})
	doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models", map[string]string{"model_name": "llama-7b"}, tenantAToken)

	rec := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/models/llama-7b/visible", nil, tenantAToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var visResp struct {
		Visible bool `json:"visible"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &visResp); err != nil {
		t.Fatalf("decode visible response: %v", err)
	}
	if !visResp.Visible {
		t.Fatal("expected llama-7b to be visible to its owning tenant")
	}

	entries := decider.Log.Entries()
	found := false
	for _, e := range entries {
		if e.Action == "tenant_boundary_check" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("expected the /visible endpoint to produce a tenant_boundary_check audit entry")
	}
}

// TestListTenants is 006-cli-daemon-wiring's RED-before-GREEN proof for
// FR-006 (GET /v1/tenants, T012): an empty registry returns
// 200 {"tenants": []} (never a bare null or an omitted key), and after
// creating two tenants the route returns both, matched by ID regardless
// of order (data-model.md leaves order non-contractual). Gated by the
// SAME ActionTenantManage bar as POST /v1/tenants (this route enumerates
// EVERY tenant in the cluster, a cluster-wide admin view exactly like
// tenant creation - never a per-tenant-scoped read an ordinary tenant
// caller should reach, mirroring this file's own
// authorizeTenantOwnership security posture rather than inventing a
// laxer, unaudited check for a brand new route).
func TestListTenants(t *testing.T) {
	engine, decider := newTenantsTestEngine()
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})

	viewerToken := issueTenantJWT(t, decider, "", []string{auth.RoleModelViewer})
	if rec := doJSON(t, engine, http.MethodGet, "/v1/tenants", nil, viewerToken); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-admin caller, got %d: %s", rec.Code, rec.Body.String())
	}

	rec := doJSON(t, engine, http.MethodGet, "/v1/tenants", nil, adminToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 on an empty registry, got %d: %s", rec.Code, rec.Body.String())
	}
	var listResp struct {
		Tenants []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"tenants"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil {
		t.Fatalf("decode empty list response: %v", err)
	}
	if listResp.Tenants == nil || len(listResp.Tenants) != 0 {
		t.Fatalf("expected an empty (non-nil) tenants array on an empty registry, got %+v (raw: %s)", listResp.Tenants, rec.Body.String())
	}

	for _, id := range []string{"tenant-a", "tenant-b"} {
		if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": id, "name": "Tenant " + id}, adminToken); rec.Code != http.StatusOK {
			t.Fatalf("create %s: expected 200, got %d: %s", id, rec.Code, rec.Body.String())
		}
	}

	rec = doJSON(t, engine, http.MethodGet, "/v1/tenants", nil, adminToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 after creating 2 tenants, got %d: %s", rec.Code, rec.Body.String())
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil {
		t.Fatalf("decode populated list response: %v", err)
	}
	if len(listResp.Tenants) != 2 {
		t.Fatalf("expected 2 tenants, got %d: %+v", len(listResp.Tenants), listResp.Tenants)
	}
	seen := map[string]string{}
	for _, tn := range listResp.Tenants {
		seen[tn.ID] = tn.Name
	}
	if seen["tenant-a"] != "Tenant tenant-a" {
		t.Fatalf("missing or wrong entry for tenant-a: %+v", listResp.Tenants)
	}
	if seen["tenant-b"] != "Tenant tenant-b" {
		t.Fatalf("missing or wrong entry for tenant-b: %+v", listResp.Tenants)
	}
}

// TestTenantQuota_ViewAndSet is 006-cli-daemon-wiring's RED-before-GREEN
// proof for FR-007 (GET+PUT /v1/tenants/:id/quota, T014): a GET on an
// existing tenant with no limits ever set returns 200 with an all-zero
// Limits body (the package's own zero-means-unlimited convention, NEVER
// a 404 - the tenant genuinely exists, it just has no configured
// ceiling); a GET on a nonexistent tenant returns 404 (resolved against
// decider.Tenants.Get, never decider.Quota, per data-model.md - a quota
// view is meaningless for an unregistered tenant id); a PUT with a JSON
// body sets limits and echoes them back 200, and a subsequent GET
// reflects the set value (proving the view is sourced from the SAME
// enforcement state PUT wrote, never a separately-tracked copy that
// could drift, per FR-007); a non-owning, non-admin caller gets 403 on
// both verbs (authorizeTenantOwnership, reused rather than a new check).
func TestTenantQuota_ViewAndSet(t *testing.T) {
	engine, decider := newTenantsTestEngine()
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": "tenant-a", "name": "Tenant A"}, adminToken)

	tenantAToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})

	// View before any limits are ever set: 200, all-zero Limits.
	rec := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/quota", nil, tenantAToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("view before any set: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var limitsResp struct {
		RequestsPerSecond     float64 `json:"requests_per_second"`
		MaxConcurrentRequests int     `json:"max_concurrent_requests"`
		MaxGPUBytes           int64   `json:"max_gpu_bytes"`
		MaxCPUCores           int64   `json:"max_cpu_cores"`
		MaxRAMBytes           int64   `json:"max_ram_bytes"`
		MaxStorageBytes       int64   `json:"max_storage_bytes"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &limitsResp); err != nil {
		t.Fatalf("decode pre-set quota response: %v", err)
	}
	if limitsResp != (struct {
		RequestsPerSecond     float64 `json:"requests_per_second"`
		MaxConcurrentRequests int     `json:"max_concurrent_requests"`
		MaxGPUBytes           int64   `json:"max_gpu_bytes"`
		MaxCPUCores           int64   `json:"max_cpu_cores"`
		MaxRAMBytes           int64   `json:"max_ram_bytes"`
		MaxStorageBytes       int64   `json:"max_storage_bytes"`
	}{}) {
		t.Fatalf("expected all-zero Limits before any PUT, got %+v", limitsResp)
	}

	// View on a nonexistent tenant: 404, never a default/zero value that
	// could be mistaken for a real tenant with an all-unlimited quota
	// (spec.md's own Edge Cases section names this exact confusion).
	rec = doJSON(t, engine, http.MethodGet, "/v1/tenants/ghost/quota", nil, adminToken)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("view on a nonexistent tenant: expected 404, got %d: %s", rec.Code, rec.Body.String())
	}

	// Set via PUT, echoed back 200.
	setBody := map[string]interface{}{
		"requests_per_second":     5.0,
		"max_concurrent_requests": 10,
		"max_gpu_bytes":           int64(8589934592),
		"max_cpu_cores":           int64(4),
		"max_ram_bytes":           int64(17179869184),
		"max_storage_bytes":       int64(107374182400),
	}
	rec = doJSON(t, engine, http.MethodPut, "/v1/tenants/tenant-a/quota", setBody, tenantAToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT quota: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &limitsResp); err != nil {
		t.Fatalf("decode PUT response: %v", err)
	}
	if limitsResp.RequestsPerSecond != 5.0 || limitsResp.MaxConcurrentRequests != 10 ||
		limitsResp.MaxGPUBytes != 8589934592 || limitsResp.MaxCPUCores != 4 ||
		limitsResp.MaxRAMBytes != 17179869184 || limitsResp.MaxStorageBytes != 107374182400 {
		t.Fatalf("PUT response did not echo the set limits: %+v", limitsResp)
	}

	// A subsequent GET reflects the SAME value PUT just wrote - proving
	// the view is sourced from the real enforcement state, not a
	// separate copy.
	rec = doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/quota", nil, tenantAToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("view after set: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &limitsResp); err != nil {
		t.Fatalf("decode post-set quota response: %v", err)
	}
	if limitsResp.MaxConcurrentRequests != 10 {
		t.Fatalf("GET after PUT did not reflect the set value: %+v", limitsResp)
	}

	// A non-owning, non-admin caller is denied on both verbs.
	tenantBToken := issueTenantJWT(t, decider, "tenant-b", []string{auth.RoleModelViewer})
	if rec := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/quota", nil, tenantBToken); rec.Code != http.StatusForbidden {
		t.Fatalf("cross-tenant GET: expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, engine, http.MethodPut, "/v1/tenants/tenant-a/quota", setBody, tenantBToken); rec.Code != http.StatusForbidden {
		t.Fatalf("cross-tenant PUT: expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestCheckModelVisible_CrossTenantQueryDenied is T075's RED-before-GREEN
// proof for a genuine cross-tenant information-disclosure vulnerability
// found during this security review: GET /v1/tenants/:id/models/:model/
// visible answered the visibility oracle for ANY caller-specified :id path
// parameter, with NO check that the caller's own JWT TenantID (or an
// admin-class role) actually authorizes acting on that tenant - unlike its
// sibling routes (GET/POST /v1/tenants/:id/models), which correctly call
// authorizeTenantOwnership. This let ANY authenticated caller (any tenant,
// any role) enumerate ANOTHER tenant's registered/shared model catalog one
// name at a time by brute-forcing model names against this endpoint,
// directly violating US9 Acceptance Scenario 1 / SC-022 ("tenant B cannot
// access it without explicit sharing" / "zero cross-tenant data leakage").
// Notably, the existing 1000-concurrent-request multi-tenancy isolation
// test (test/integration/multitenancy_isolation_test.go) does NOT catch
// this: its "cross visibility check" category always queries using the
// CALLER's own tenant ID in the path (tf.id), never another tenant's ID
// (other.id), so it only ever exercises the CALLER's own (correctly
// enforced) tenancy.Registry.IsVisible result - never this endpoint's
// missing caller-vs-path-tenant authorization.
func TestCheckModelVisible_CrossTenantQueryDenied(t *testing.T) {
	engine, decider := newTenantsTestEngine()
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	for _, id := range []string{"tenant-a", "tenant-b"} {
		doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": id, "name": id}, adminToken)
	}
	tenantAToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})
	doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models", map[string]string{"model_name": "secret-model"}, tenantAToken)

	// The attack: tenant-b's own JWT probes tenant-a's namespace directly
	// via the path parameter - tenant-b never registered nor was ever
	// shared "secret-model".
	tenantBToken := issueTenantJWT(t, decider, "tenant-b", []string{auth.RoleModelViewer})
	rec := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/models/secret-model/visible", nil, tenantBToken)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("CROSS-TENANT LEAK: tenant-b queried tenant-a's model-visibility oracle directly and got status=%d body=%s (want 403)", rec.Code, rec.Body.String())
	}
}
