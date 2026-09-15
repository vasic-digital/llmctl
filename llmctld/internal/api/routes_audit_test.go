package api

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
)

func newAuditTestEngine() (*gin.Engine, *authz.Decider) {
	e, d := newDeciderAndEngine()
	RegisterAuditRoutes(e, d)
	return e, d
}

// TestAuditEntries_RequiresAdminRole proves the audit-query endpoint is
// admin/tenant-admin-only (an operator-facing capability, never
// self-service for an ordinary caller).
func TestAuditEntries_RequiresAdminRole(t *testing.T) {
	engine, decider := newAuditTestEngine()

	decider.Log.Append("someone", "rbac_check", "model-x", "allow")

	viewerToken := issueTenantJWT(t, decider, "", []string{auth.RoleModelViewer})
	if rec := doJSON(t, engine, http.MethodGet, "/v1/audit/entries", nil, viewerToken); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-admin caller, got %d: %s", rec.Code, rec.Body.String())
	}

	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	rec := doJSON(t, engine, http.MethodGet, "/v1/audit/entries", nil, adminToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for an admin caller, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Entries []struct {
			Actor    string `json:"actor"`
			Action   string `json:"action"`
			Decision string `json:"decision"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode entries response: %v", err)
	}
	if len(resp.Entries) < 1 {
		t.Fatal("expected at least the pre-seeded entry to be returned")
	}
}

// TestAuditVerify_ReportsCleanChain proves GET /v1/audit/verify surfaces
// the real audit.Log.VerifyChain result (Constitution §11.4.268's
// tamper-evidence guarantee, exposed operationally).
func TestAuditVerify_ReportsCleanChain(t *testing.T) {
	engine, decider := newAuditTestEngine()
	decider.Log.Append("someone", "rbac_check", "model-x", "allow")
	decider.Log.Append("someone-else", "quota_check", "tenant-a", "deny")

	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	rec := doJSON(t, engine, http.MethodGet, "/v1/audit/verify", nil, adminToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Ok bool `json:"ok"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode verify response: %v", err)
	}
	if !resp.Ok {
		t.Fatal("expected a clean, untampered chain to verify ok=true")
	}
}
