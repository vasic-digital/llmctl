package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

func newAuthTestEngine() (*gin.Engine, *authz.Decider, *auth.Store) {
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	decider := authz.NewDecider(audit.NewLog(), []byte("test-signing-key"), auth.NewRoleRegistry(), tenancy.NewEnforcer(), tenancy.NewRegistry())
	keys := auth.NewKeyStore()
	RegisterAuthRoutes(engine, decider, keys)
	return engine, decider, keys
}

func doJSON(t *testing.T, engine *gin.Engine, method, path string, body interface{}, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)
	return rec
}

// TestTokenExchange_ValidAPIKeyIssuesJWT proves the token-exchange
// bootstrap flow: POST /v1/auth/token is NOT behind RequireJWT (it is how
// a caller gets its FIRST JWT), and a valid API key round-trips into a
// real JWT whose claims (TenantID/Roles) are derived from the key's
// scopes.
func TestTokenExchange_ValidAPIKeyIssuesJWT(t *testing.T) {
	engine, decider, keys := newAuthTestEngine()
	id, secret, err := keys.Create("owner-1", []string{"tenant:tenant-a", auth.RoleModelViewer}, 0)
	if err != nil {
		t.Fatalf("create key: %v", err)
	}

	rec := doJSON(t, engine, http.MethodPost, "/v1/auth/token", map[string]string{
		"api_key_id":     id,
		"api_key_secret": secret,
	}, "")

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Token == "" {
		t.Fatal("expected a non-empty token")
	}

	claims, err := decider.ValidateToken(resp.Token, "test", "test")
	if err != nil {
		t.Fatalf("issued token should validate: %v", err)
	}
	if claims.Subject != "owner-1" {
		t.Fatalf("expected Subject=owner-1, got %q", claims.Subject)
	}
	if claims.TenantID != "tenant-a" {
		t.Fatalf("expected TenantID=tenant-a (from the tenant: scope), got %q", claims.TenantID)
	}
	if len(claims.Roles) != 1 || claims.Roles[0] != auth.RoleModelViewer {
		t.Fatalf("expected Roles=[model-viewer], got %v", claims.Roles)
	}
}

func TestTokenExchange_InvalidSecretRejectedWith401(t *testing.T) {
	engine, _, keys := newAuthTestEngine()
	id, _, err := keys.Create("owner-1", nil, 0)
	if err != nil {
		t.Fatalf("create key: %v", err)
	}

	rec := doJSON(t, engine, http.MethodPost, "/v1/auth/token", map[string]string{
		"api_key_id":     id,
		"api_key_secret": "wrong-secret",
	}, "")

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

// TestCreateAPIKey_PrivilegeEscalation_NonAdminCannotSelfMintAdminKey is
// T075's RED-before-GREEN proof for a genuine, critical privilege-
// escalation vulnerability found during this security review:
// POST /v1/auth/apikeys was gated by RequireJWT ONLY - any caller holding
// merely a VALID (but arbitrarily low-privileged) JWT could self-mint a
// BRAND NEW API key with Scopes=["admin"], then immediately exchange that
// key via POST /v1/auth/token for a fully admin-privileged JWT, completely
// bypassing RBAC (FR-031). This proves a caller holding only
// RoleModelViewer is denied (403) when it attempts to create an
// admin-scoped key for itself, closing the escalation path; API-key
// lifecycle management is an admin-managed resource end-to-end, exactly
// like tenant creation (routes_tenants.go) and audit-log access
// (routes_audit.go), never self-service for an arbitrary authenticated
// caller.
func TestCreateAPIKey_PrivilegeEscalation_NonAdminCannotSelfMintAdminKey(t *testing.T) {
	engine, _, keys := newAuthTestEngine()

	// A low-privileged caller (model-viewer, no tenant) obtains a real JWT
	// exactly as any ordinary authenticated user would.
	viewerID, viewerSecret, err := keys.Create("viewer-owner", []string{auth.RoleModelViewer}, 0)
	if err != nil {
		t.Fatalf("create viewer key: %v", err)
	}
	tokenRec := doJSON(t, engine, http.MethodPost, "/v1/auth/token", map[string]string{
		"api_key_id":     viewerID,
		"api_key_secret": viewerSecret,
	}, "")
	var tokenResp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(tokenRec.Body.Bytes(), &tokenResp); err != nil {
		t.Fatalf("decode token response: %v", err)
	}
	if tokenResp.Token == "" {
		t.Fatal("expected the viewer key to exchange for a real JWT")
	}

	// The attack: attempt to self-mint a brand-new API key scoped to
	// "admin" using ONLY the viewer's own low-privileged JWT.
	escalateRec := doJSON(t, engine, http.MethodPost, "/v1/auth/apikeys", map[string]interface{}{
		"owner_id": "attacker",
		"scopes":   []string{auth.RoleAdmin},
	}, tokenResp.Token)
	if escalateRec.Code != http.StatusForbidden {
		t.Fatalf("PRIVILEGE ESCALATION: a model-viewer-scoped caller was able to self-mint an admin-scoped API key: status = %d, body = %s (want 403)", escalateRec.Code, escalateRec.Body.String())
	}

	// Sanity/negative-control: a caller holding a role granting
	// tenant:manage (admin) can still legitimately create API keys - the
	// gate must deny the escalation, not deny key creation outright.
	adminID, adminSecret, err := keys.Create("admin-owner", []string{auth.RoleAdmin}, 0)
	if err != nil {
		t.Fatalf("create admin key: %v", err)
	}
	adminTokenRec := doJSON(t, engine, http.MethodPost, "/v1/auth/token", map[string]string{
		"api_key_id":     adminID,
		"api_key_secret": adminSecret,
	}, "")
	var adminTokenResp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(adminTokenRec.Body.Bytes(), &adminTokenResp); err != nil {
		t.Fatalf("decode admin token response: %v", err)
	}
	adminCreateRec := doJSON(t, engine, http.MethodPost, "/v1/auth/apikeys", map[string]interface{}{
		"owner_id": "legit-service-account",
		"scopes":   []string{auth.RoleModelViewer},
	}, adminTokenResp.Token)
	if adminCreateRec.Code != http.StatusOK {
		t.Fatalf("expected an admin caller to still be able to create API keys, got %d: %s", adminCreateRec.Code, adminCreateRec.Body.String())
	}
}

// TestRotateRevokeAPIKey_RequiresTenantManageRole proves the SAME
// ActionTenantManage gate applies to key rotation and revocation, not only
// creation - closing the same class of missing-authorization gap
// symmetrically across the whole API-key lifecycle.
func TestRotateRevokeAPIKey_RequiresTenantManageRole(t *testing.T) {
	engine, _, keys := newAuthTestEngine()

	targetID, _, err := keys.Create("some-owner", []string{auth.RoleModelViewer}, 0)
	if err != nil {
		t.Fatalf("create target key: %v", err)
	}

	viewerID, viewerSecret, err := keys.Create("viewer-owner", []string{auth.RoleModelViewer}, 0)
	if err != nil {
		t.Fatalf("create viewer key: %v", err)
	}
	tokenRec := doJSON(t, engine, http.MethodPost, "/v1/auth/token", map[string]string{
		"api_key_id":     viewerID,
		"api_key_secret": viewerSecret,
	}, "")
	var tokenResp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(tokenRec.Body.Bytes(), &tokenResp); err != nil {
		t.Fatalf("decode token response: %v", err)
	}

	if rec := doJSON(t, engine, http.MethodPost, "/v1/auth/apikeys/"+targetID+"/rotate", nil, tokenResp.Token); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-admin caller rotating ANOTHER owner's key, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, engine, http.MethodDelete, "/v1/auth/apikeys/"+targetID, nil, tokenResp.Token); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-admin caller revoking ANOTHER owner's key, got %d: %s", rec.Code, rec.Body.String())
	}

	// The target key must still be fully unrevoked - a denied revoke
	// attempt must never have partially mutated it. (Rotate would change
	// the secret, which this test never learns, so revocation status is
	// the observable that proves nothing landed.)
	if err := keys.Revoke(targetID); err != nil {
		t.Fatalf("expected the target key to still be revocable (i.e. never actually revoked by the denied attempt above): %v", err)
	}
}

// TestAPIKeyLifecycle_CreateRotateRevoke_RequiresJWT proves the key
// management endpoints are behind RequireJWT (unlike token exchange
// itself), and that FR-032's rotation guarantee holds end-to-end through
// the HTTP layer: an old secret is rejected immediately after rotation.
func TestAPIKeyLifecycle_CreateRotateRevoke_RequiresJWT(t *testing.T) {
	engine, _, keys := newAuthTestEngine()
	bootstrapID, bootstrapSecret, err := keys.Create("bootstrap-owner", []string{auth.RoleAdmin}, 0)
	if err != nil {
		t.Fatalf("create bootstrap key: %v", err)
	}
	tokenRec := doJSON(t, engine, http.MethodPost, "/v1/auth/token", map[string]string{
		"api_key_id":     bootstrapID,
		"api_key_secret": bootstrapSecret,
	}, "")
	var tokenResp struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(tokenRec.Body.Bytes(), &tokenResp); err != nil {
		t.Fatalf("decode token response: %v", err)
	}

	// No bearer token -> 401, never reaches the handler.
	if rec := doJSON(t, engine, http.MethodPost, "/v1/auth/apikeys", map[string]interface{}{"owner_id": "user-2", "scopes": []string{}}, ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without a bearer token, got %d", rec.Code)
	}

	// With a valid bearer token -> create succeeds.
	createRec := doJSON(t, engine, http.MethodPost, "/v1/auth/apikeys", map[string]interface{}{"owner_id": "user-2", "scopes": []string{"model-viewer"}}, tokenResp.Token)
	if createRec.Code != http.StatusOK {
		t.Fatalf("expected 200 creating a key, got %d: %s", createRec.Code, createRec.Body.String())
	}
	var created struct {
		ID     string `json:"id"`
		Secret string `json:"secret"`
	}
	if err := json.Unmarshal(createRec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}

	if _, err := keys.Validate(created.ID, created.Secret); err != nil {
		t.Fatalf("expected the created key to validate: %v", err)
	}

	rotateRec := doJSON(t, engine, http.MethodPost, "/v1/auth/apikeys/"+created.ID+"/rotate", nil, tokenResp.Token)
	if rotateRec.Code != http.StatusOK {
		t.Fatalf("expected 200 rotating a key, got %d: %s", rotateRec.Code, rotateRec.Body.String())
	}
	var rotated struct {
		Secret string `json:"secret"`
	}
	if err := json.Unmarshal(rotateRec.Body.Bytes(), &rotated); err != nil {
		t.Fatalf("decode rotate response: %v", err)
	}
	if _, err := keys.Validate(created.ID, created.Secret); err == nil {
		t.Fatal("expected the OLD secret to be rejected immediately after rotation (FR-032)")
	}
	if _, err := keys.Validate(created.ID, rotated.Secret); err != nil {
		t.Fatalf("expected the NEW secret to validate: %v", err)
	}

	revokeRec := doJSON(t, engine, http.MethodDelete, "/v1/auth/apikeys/"+created.ID, nil, tokenResp.Token)
	if revokeRec.Code != http.StatusOK {
		t.Fatalf("expected 200 revoking a key, got %d: %s", revokeRec.Code, revokeRec.Body.String())
	}
	if _, err := keys.Validate(created.ID, rotated.Secret); err == nil {
		t.Fatal("expected a revoked key to be rejected")
	}
}
