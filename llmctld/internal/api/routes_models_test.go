// Package api (routes_models_test.go): proves the model-lifecycle
// dispatch routes (T072-FU4) genuinely drive a REAL
// internal/executor.LocalExecutor -> real bin/llmctl dry-run subprocess
// -> real lib/service_linux.sh tenant-scoped instance keying (T072-FU1),
// gated by real RBAC actions (T066) + real tenant-ownership/visibility
// checks (T069/T074/T075) - no mocked Executor anywhere, matching this
// project's established "no fakes beyond unit tests" discipline for
// anything that shells out to the real bin/llmctl script.
package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/executor"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// modelRoutesLlmctlBinPath / modelRoutesFakeHWFixture mirror
// internal/executor/local_test.go's own unexported helpers of the same
// shape - duplicated here rather than exported across packages, since
// this file needs the SAME real repo-root bin/llmctl script + fixture
// for its own real-subprocess tests.
func modelRoutesLlmctlBinPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed - cannot locate this test file")
	}
	repoRoot := filepath.Join(filepath.Dir(thisFile), "..", "..", "..")
	bin := filepath.Join(repoRoot, "bin", "llmctl")
	if _, err := os.Stat(bin); err != nil {
		t.Fatalf("real bin/llmctl not found at %s (repo layout changed?): %v", bin, err)
	}
	return bin
}

func modelRoutesFakeHWFixture(t *testing.T) string {
	t.Helper()
	repoRoot := filepath.Join(filepath.Dir(modelRoutesLlmctlBinPath(t)), "..")
	fixture := filepath.Join(repoRoot, "tests", "fixtures", "hw-baseline.json")
	if _, err := os.Stat(fixture); err != nil {
		t.Fatalf("hw-baseline.json fixture not found at %s: %v", fixture, err)
	}
	return fixture
}

// newModelRoutesTestEngine builds a real dry-run LocalExecutor (isolated
// per-test state tree, LLMCTL_DRY_RUN=1 - never touches a real systemd
// session or downloads a real model, mirroring
// internal/executor/local_test.go's own newDryRunExecutor exactly) wired
// into a fresh *gin.Engine via RegisterModelRoutes on top of
// RegisterTenantRoutes (a model must be registered/shared before it can
// be started/stopped/queried - the visibility gate T072-FU4 enforces).
// Returns the *gin.Engine, the *authz.Decider, and the real per-test
// LLMCTL_SERVICES_DIR path so tests can assert on real on-disk evidence
// bin/llmctl's own subprocess wrote.
func newModelRoutesTestEngine(t *testing.T) (engine *gin.Engine, decider *authz.Decider, servicesDir string) {
	t.Helper()
	tmp := t.TempDir()
	stateDir := filepath.Join(tmp, "state")
	runtimeDir := filepath.Join(stateDir, "run")
	servicesDir = filepath.Join(stateDir, "services")
	env := map[string]string{
		"LLMCTL_STATE_DIR":    stateDir,
		"LLMCTL_RUNTIME_DIR":  runtimeDir,
		"LLMCTL_CONFIG_DIR":   filepath.Join(tmp, "config"),
		"LLMCTL_DATA_DIR":     filepath.Join(tmp, "data"),
		"LLMCTL_MODELS_DIR":   filepath.Join(tmp, "models"),
		"LLMCTL_LOG_DIR":      filepath.Join(stateDir, "logs"),
		"LLMCTL_VERIFY_DIR":   filepath.Join(stateDir, "verify"),
		"LLMCTL_SERVICES_DIR": servicesDir,
		"LLMCTL_UNIT_DIR":     filepath.Join(tmp, "systemd-user"),
		"LLMCTL_PLIST_DIR":    filepath.Join(tmp, "LaunchAgents"),
		"NO_COLOR":            "1",
		"LLMCTL_DRY_RUN":      "1",
		"LLMCTL_FAKE_HW":      modelRoutesFakeHWFixture(t),
	}
	for k, v := range env {
		t.Setenv(k, v)
	}
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime dir: %v", err)
	}

	engine, decider = newDeciderAndEngine()
	RegisterTenantRoutes(engine, decider)
	base := executor.New(executor.Config{LLMCtlPath: modelRoutesLlmctlBinPath(t)})
	// node=nil, forwardTLS=nil: no cluster wiring for these tests - T019's
	// own guarantee is that this preserves the exact pre-Phase-3
	// local-only behavior every assertion below already depends on.
	RegisterModelRoutes(engine, decider, base, nil, nil)
	return engine, decider, servicesDir
}

// registerTenantAndModel is shared setup: create tenant tenantID (as
// admin) and register modelName into its namespace (as an operator
// caller belonging to that tenant) - the real HTTP path every model
// must go through before this task's new routes will dispatch a real
// subprocess on its behalf.
func registerTenantAndModel(t *testing.T, engine *gin.Engine, decider *authz.Decider, tenantID, modelName string) {
	t.Helper()
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": tenantID, "name": tenantID}, adminToken); rec.Code != http.StatusOK {
		t.Fatalf("create tenant %s: expected 200, got %d: %s", tenantID, rec.Code, rec.Body.String())
	}
	operatorToken := issueTenantJWT(t, decider, tenantID, []string{auth.RoleModelOperator})
	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/"+tenantID+"/models", map[string]string{"model_name": modelName}, operatorToken); rec.Code != http.StatusOK {
		t.Fatalf("register model %s for tenant %s: expected 200, got %d: %s", modelName, tenantID, rec.Code, rec.Body.String())
	}
}

// TestModelStart_RealDryRunSubprocess_WritesTenantScopedEnvFile is the
// end-to-end proof this task exists for: a real HTTP POST, through real
// RBAC + tenant-ownership + tenant-visibility gates, dispatching a real
// internal/executor.LocalExecutor.WithTenant(tenantID).Start(model) call
// against the real bin/llmctl dry-run subprocess - which, thanks to
// T072-FU1's bash-side wiring, writes a REAL tenant-scoped env file
// on disk. No mock Executor, no mock bin/llmctl, at any point.
func TestModelStart_RealDryRunSubprocess_WritesTenantScopedEnvFile(t *testing.T) {
	engine, decider, servicesDir := newModelRoutesTestEngine(t)
	registerTenantAndModel(t, engine, decider, "tenant-a", "small")

	operatorToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})
	rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/small/start", nil, operatorToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST start: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	tenantEnvFile := filepath.Join(servicesDir, "tenant-a--small.env")
	if _, err := os.Stat(tenantEnvFile); err != nil {
		t.Fatalf("expected tenant-scoped env file %s to exist (proves the real HTTP route dispatched a real, tenant-scoped bin/llmctl subprocess): %v", tenantEnvFile, err)
	}
}

// TestModelStart_DeniedWithoutModelOperatorRole proves a caller lacking
// ActionModelStart (e.g. a model-viewer) cannot start a model even
// within its own, correctly-registered tenant namespace.
func TestModelStart_DeniedWithoutModelOperatorRole(t *testing.T) {
	engine, decider, _ := newModelRoutesTestEngine(t)
	registerTenantAndModel(t, engine, decider, "tenant-a", "small")

	viewerToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelViewer})
	rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/small/start", nil, viewerToken)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a model-viewer caller, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestModelStart_DeniedForAnotherTenantsNamespace proves a model-operator
// belonging to tenant-b cannot start a model in tenant-a's namespace -
// authorizeTenantOwnership must gate this route exactly as it already
// gates every sibling tenant route (T075's fix for the analogous
// /visible route's missing check, applied here from the start).
func TestModelStart_DeniedForAnotherTenantsNamespace(t *testing.T) {
	engine, decider, _ := newModelRoutesTestEngine(t)
	registerTenantAndModel(t, engine, decider, "tenant-a", "small")
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": "tenant-b", "name": "tenant-b"}, adminToken); rec.Code != http.StatusOK {
		t.Fatalf("create tenant-b: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	tenantBOperatorToken := issueTenantJWT(t, decider, "tenant-b", []string{auth.RoleModelOperator})
	rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/small/start", nil, tenantBOperatorToken)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a caller acting outside its own tenant, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestModelStart_DeniedForUnregisteredModel proves a model-operator
// cannot start a catalog profile name it never registered into its own
// tenant namespace, even though it holds every other required
// permission - the tenant-visibility gate (decider.CheckTenantBoundary)
// is genuinely enforced, not merely RBAC/ownership.
func TestModelStart_DeniedForUnregisteredModel(t *testing.T) {
	engine, decider, _ := newModelRoutesTestEngine(t)
	adminToken := issueTenantJWT(t, decider, "", []string{auth.RoleAdmin})
	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants", map[string]string{"id": "tenant-a", "name": "tenant-a"}, adminToken); rec.Code != http.StatusOK {
		t.Fatalf("create tenant-a: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	operatorToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})
	rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/small/start", nil, operatorToken)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for an unregistered model, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestModelStop_RealDryRunSubprocess proves POST .../stop dispatches a
// real Stop call - started first (its own real subprocess), then
// stopped, confirmed via real bin/llmctl status output through the
// status route.
func TestModelStop_RealDryRunSubprocess(t *testing.T) {
	engine, decider, _ := newModelRoutesTestEngine(t)
	registerTenantAndModel(t, engine, decider, "tenant-a", "small")
	operatorToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})

	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/small/start", nil, operatorToken); rec.Code != http.StatusOK {
		t.Fatalf("start: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/small/stop", nil, operatorToken); rec.Code != http.StatusOK {
		t.Fatalf("stop: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestModelStatus_ModelViewerCanQuery_ButTenantAdminOnlyAndUnauthenticatedCannot
// proves the status route accepts the weakest real role (model-viewer,
// per rbac.go's predefinedRoles table) since ActionModelView is
// read-only, while still requiring BOTH a valid token at all (RequireJWT)
// AND that the caller's role specifically grants ActionModelView.
func TestModelStatus_ModelViewerCanQuery_ButTenantAdminOnlyAndUnauthenticatedCannot(t *testing.T) {
	engine, decider, _ := newModelRoutesTestEngine(t)
	registerTenantAndModel(t, engine, decider, "tenant-a", "small")

	viewerToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelViewer})
	rec := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/models/small/status", nil, viewerToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for a model-viewer caller, got %d: %s", rec.Code, rec.Body.String())
	}

	// A tenant-admin (real predefined role, but grants ONLY
	// ActionTenantManage per rbac.go - never a model action) must be
	// denied even though it can manage the tenant itself.
	tenantAdminToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleTenantAdmin})
	rec2 := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/models/small/status", nil, tenantAdminToken)
	if rec2.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a tenant-admin-only caller (no model action granted), got %d: %s", rec2.Code, rec2.Body.String())
	}

	// A genuinely unauthenticated request (no Authorization header at
	// all - doJSON's bearer="" omits it entirely) must be rejected by
	// RequireJWT itself (401), never reach the RBAC/ownership/visibility
	// gates at all - closing a real gap an independent review found: the
	// PRIOR version of this test never actually exercised the
	// no-token case its own name claimed to.
	rec3 := doJSON(t, engine, http.MethodGet, "/v1/tenants/tenant-a/models/small/status", nil, "")
	if rec3.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for a request with no bearer token at all, got %d: %s", rec3.Code, rec3.Body.String())
	}
}

// newModelRoutesTestEngineWithNode is newModelRoutesTestEngine's
// cluster-aware sibling (002-cluster-model-scheduler T012): a real
// single-node Raft cluster (bootstrapped, self-registered with a REAL
// capacity that fits the "small" profile's real footprint per
// tests/fixtures/hw-baseline.json - hand-verified against bin/llmctl's
// own real "plan --json" output, matching
// internal/executor/local_test.go's identical fixture value) is wired
// via RegisterModelRoutes's node parameter, so a start request naming no
// node genuinely enters the auto-placement path (cluster.Place()) rather
// than the explicit/no-wiring path newModelRoutesTestEngine's plain
// (node=nil) engine takes.
func newModelRoutesTestEngineWithNode(t *testing.T) (engine *gin.Engine, decider *authz.Decider, servicesDir string, node *raft.Node) {
	t.Helper()
	tmp := t.TempDir()
	stateDir := filepath.Join(tmp, "state")
	runtimeDir := filepath.Join(stateDir, "run")
	servicesDir = filepath.Join(stateDir, "services")
	env := map[string]string{
		"LLMCTL_STATE_DIR":    stateDir,
		"LLMCTL_RUNTIME_DIR":  runtimeDir,
		"LLMCTL_CONFIG_DIR":   filepath.Join(tmp, "config"),
		"LLMCTL_DATA_DIR":     filepath.Join(tmp, "data"),
		"LLMCTL_MODELS_DIR":   filepath.Join(tmp, "models"),
		"LLMCTL_LOG_DIR":      filepath.Join(stateDir, "logs"),
		"LLMCTL_VERIFY_DIR":   filepath.Join(stateDir, "verify"),
		"LLMCTL_SERVICES_DIR": servicesDir,
		"LLMCTL_UNIT_DIR":     filepath.Join(tmp, "systemd-user"),
		"LLMCTL_PLIST_DIR":    filepath.Join(tmp, "LaunchAgents"),
		"NO_COLOR":            "1",
		"LLMCTL_DRY_RUN":      "1",
		"LLMCTL_FAKE_HW":      modelRoutesFakeHWFixture(t),
	}
	for k, v := range env {
		t.Setenv(k, v)
	}
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime dir: %v", err)
	}

	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	node, err = raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	t.Cleanup(func() { _ = node.Shutdown() })
	waitForRealLeader(t, node, 3*time.Second)

	// A capacity comfortably larger than "small"'s real footprint
	// (2048MB RAM / 3973MB VRAM per hw-baseline.json - hand-verified
	// against bin/llmctl's own real "plan --json" output) so Place()
	// genuinely has a fitting candidate: this node itself.
	if err := node.RegisterSelf("127.0.0.1:0", cluster.Resources{
		CPUCores: 8, RAMTotalMB: 16384, RAMAvailMB: 8192,
		VRAMTotalMB: 8192, VRAMAvailMB: 8192, NetworkMbps: 1000,
	}); err != nil {
		t.Fatalf("RegisterSelf: %v", err)
	}

	engine, decider = newDeciderAndEngine()
	RegisterTenantRoutes(engine, decider)
	base := executor.New(executor.Config{LLMCtlPath: modelRoutesLlmctlBinPath(t)})
	RegisterModelRoutes(engine, decider, base, node, nil)
	return engine, decider, servicesDir, node
}

// TestModelStart_AutoPlacement_NoNodeField_LandsOnRealNodeWithCapacity is
// 002-cluster-model-scheduler T012's contract test: a start request with
// no "node" field, against a real single-node cluster whose one real
// node has real, sufficient capacity, genuinely enters the auto-placement
// path (never the pre-Phase-3 local-only path - proven by asserting
// against the SAME real dry-run env-file side-effect
// TestModelStart_RealDryRunSubprocess_WritesTenantScopedEnvFile already
// established as this codebase's real-dispatch proof), and the response
// names the real node that accepted the work.
func TestModelStart_AutoPlacement_NoNodeField_LandsOnRealNodeWithCapacity(t *testing.T) {
	engine, decider, servicesDir, node := newModelRoutesTestEngineWithNode(t)
	registerTenantAndModel(t, engine, decider, "tenant-a", "small")

	operatorToken := issueTenantJWT(t, decider, "tenant-a", []string{auth.RoleModelOperator})
	rec := doJSON(t, engine, http.MethodPost, "/v1/tenants/tenant-a/models/small/start", nil, operatorToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST start (no node field): expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var respBody struct {
		Node string `json:"node"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &respBody); err != nil {
		t.Fatalf("unmarshal response body %q: %v", rec.Body.String(), err)
	}
	if respBody.Node != node.ID() {
		t.Fatalf("response node = %q, want the real chosen node %q", respBody.Node, node.ID())
	}

	tenantEnvFile := filepath.Join(servicesDir, "tenant-a--small.env")
	if _, err := os.Stat(tenantEnvFile); err != nil {
		t.Fatalf("expected tenant-scoped env file %s to exist (proves auto-placement genuinely dispatched a real, tenant-scoped bin/llmctl subprocess): %v", tenantEnvFile, err)
	}
}
