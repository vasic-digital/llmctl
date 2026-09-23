// Package integration (cluster_placement_test.go): 002-cluster-model-
// scheduler's User Story 1 real multi-process integration tests (T013,
// T014) - a real 3-node cluster (real OS processes, real Raft, real
// HTTP/3+mTLS cluster APIs), each node's real bin/llmctl subprocess
// reporting a DIFFERENT real hardware capacity via a distinct
// LLMCTL_FAKE_HW fixture, proving a start request naming no node
// genuinely lands on whichever real node has room (or is refused with
// the exact real shortfall when none does) - never a mock, never an
// in-process fake, matching this package's established
// cluster_bootstrap_test.go/multitenancy_isolation_test.go discipline.
//
// Honest scope boundary (mirroring multitenancy_isolation_test.go's own
// disclosed boundary #1): tenant/model registry is per-node, not
// cross-node-replicated - this test registers the tenant + model
// identically on every real node before exercising auto-placement, so
// the receiving node AND whichever node the request is forwarded to both
// independently authorize the request against their own real, in-memory
// tenancy state.
package integration

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// llmctlBinPath resolves the real repo-root bin/llmctl script's path,
// relative to this test file's own package directory (`go test` always
// runs with cwd = the package directory) - mirroring
// internal/api/routes_models_test.go's modelRoutesLlmctlBinPath and this
// package's own buildLLMCtld's identical "../../cmd/llmctld"-style
// relative resolution, never a guessed absolute path.
func llmctlBinPath(t *testing.T) string {
	t.Helper()
	bin, err := filepath.Abs(filepath.Join("..", "..", "..", "bin", "llmctl"))
	if err != nil {
		t.Fatalf("resolve bin/llmctl path: %v", err)
	}
	if _, err := os.Stat(bin); err != nil {
		t.Fatalf("real bin/llmctl not found at %s (repo layout changed?): %v", bin, err)
	}
	return bin
}

// fixturePath resolves one of tests/fixtures/*.json's real, repo-root-
// relative paths, exactly like llmctlBinPath.
func fixturePath(t *testing.T, name string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "..", "tests", "fixtures", name))
	if err != nil {
		t.Fatalf("resolve fixture path %q: %v", name, err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("fixture %s not found: %v", p, err)
	}
	return p
}

// nodeDryRunEnv builds the full set of LLMCTL_* dry-run environment
// variables one real spawned node's real bin/llmctl subprocess needs,
// isolated under its own scratch subdirectory of dir (so every node's
// real dry-run state - including the tenant-scoped env files T072-FU1's
// bash-side wiring writes on a real Start() - lives at a distinct,
// independently-inspectable path this test can assert against directly),
// reporting hwFixture as its real probed hardware.
func nodeDryRunEnv(dir, nodeID, hwFixture string) (env []string, servicesDir string) {
	root := filepath.Join(dir, nodeID)
	stateDir := filepath.Join(root, "state")
	servicesDir = filepath.Join(stateDir, "services")
	return []string{
		"LLMCTL_STATE_DIR=" + stateDir,
		"LLMCTL_RUNTIME_DIR=" + filepath.Join(stateDir, "run"),
		"LLMCTL_CONFIG_DIR=" + filepath.Join(root, "config"),
		"LLMCTL_DATA_DIR=" + filepath.Join(root, "data"),
		"LLMCTL_MODELS_DIR=" + filepath.Join(root, "models"),
		"LLMCTL_LOG_DIR=" + filepath.Join(stateDir, "logs"),
		"LLMCTL_VERIFY_DIR=" + filepath.Join(stateDir, "verify"),
		"LLMCTL_SERVICES_DIR=" + servicesDir,
		"LLMCTL_UNIT_DIR=" + filepath.Join(root, "systemd-user"),
		"LLMCTL_PLIST_DIR=" + filepath.Join(root, "LaunchAgents"),
		"NO_COLOR=1",
		"LLMCTL_DRY_RUN=1",
		"LLMCTL_FAKE_HW=" + hwFixture,
	}, servicesDir
}

// bootstrapWithHW spawns the cluster's REAL first node exactly like
// multitenancy_isolation_test.go's bootstrapWithAdmin (same
// "-bootstrap-admin" real admin-key-seeding mechanism, so this file's
// tests can independently mint tenant credentials with no pre-existing
// JWT to start from), additionally wired with -llmctl-path (this
// process's own real bin/llmctl) and a real dry-run environment reporting
// hwFixture as its real hardware - the mechanism this file's tests need
// to make different real nodes report different real capacities.
func (tc *testCluster) bootstrapWithHW(nodeID, hwFixture string) (n *spawnedNode, adminKeyID, adminKeySecret string) {
	tc.t.Helper()
	caCert := filepath.Join(tc.dir, "ca.crt")
	caKey := filepath.Join(tc.dir, "ca.key")
	env, _ := nodeDryRunEnv(tc.dir, nodeID, hwFixture)

	n = tc.spawn(nodeID, "bootstrap", env,
		"-node-id="+nodeID,
		"-raft-bind=127.0.0.1:0",
		"-api-bind=127.0.0.1:0",
		"-ca-cert="+caCert,
		"-ca-key="+caKey,
		"-bootstrap-admin",
		"-llmctl-path="+llmctlBinPath(tc.t),
	)

	certPEM, err := os.ReadFile(caCert)
	if err != nil {
		tc.t.Fatalf("read CA cert written by bootstrap node %q: %v", nodeID, err)
	}
	keyPEM, err := os.ReadFile(caKey)
	if err != nil {
		tc.t.Fatalf("read CA key written by bootstrap node %q: %v", nodeID, err)
	}
	ca, err := mtls.LoadCA(certPEM, keyPEM)
	if err != nil {
		tc.t.Fatalf("mtls.LoadCA on the bootstrap node's own CA output: %v", err)
	}
	tc.ca = ca

	m := bootstrapAdminKeyLine.FindStringSubmatch(n.logBuf.String())
	if m == nil {
		tc.t.Fatalf("node %q never printed a BOOTSTRAP_ADMIN_KEY_ID=... BOOTSTRAP_ADMIN_KEY_SECRET=... line; captured output:\n%s", nodeID, n.logBuf.String())
	}

	return n, m[1], m[2]
}

// joinWithHW spawns a REAL additional node via `llmctld cluster join`,
// wired identically to bootstrapWithHW (own -llmctl-path + own dry-run
// hardware fixture).
func (tc *testCluster) joinWithHW(nodeID string, leader *spawnedNode, hwFixture string) (n *spawnedNode, servicesDir string) {
	tc.t.Helper()
	env, svcDir := nodeDryRunEnv(tc.dir, nodeID, hwFixture)
	n = tc.spawn(nodeID, "join", env,
		"-node-id="+nodeID,
		"-raft-bind=127.0.0.1:0",
		"-api-bind=127.0.0.1:0",
		"-ca-cert="+filepath.Join(tc.dir, "ca.crt"),
		"-ca-key="+filepath.Join(tc.dir, "ca.key"),
		"-leader-api="+leader.apiAddr,
		"-llmctl-path="+llmctlBinPath(tc.t),
	)
	return n, svcDir
}

// startModelResp mirrors internal/api's own gin.H JSON response shape for
// POST .../start (routes_models.go) - a plain, decoupled local type
// matching only the JSON contract, per this package's established
// duplication-over-import-of-unexported-types pattern.
type startModelResp struct {
	Status     string                `json:"status"`
	Model      string                `json:"model"`
	Node       string                `json:"node"`
	Error      string                `json:"error"`
	Reason     string                `json:"reason"`
	Considered []nodeCapacitySnapEnv `json:"considered"`
}

// nodeCapacitySnapEnv mirrors cluster.NodeCapacitySnapshot's JSON shape.
type nodeCapacitySnapEnv struct {
	NodeID    string `json:"node_id"`
	Resources struct {
		RAMAvailMB  int64 `json:"ram_avail_mb"`
		VRAMAvailMB int64 `json:"vram_avail_mb"`
	} `json:"resources"`
}

// startModelAutoPlaced calls the extended POST .../start route with NO
// "node" field (Go's zero-value struct, marshaled as {} - the exact
// absent-field shape 002-cluster-model-scheduler's auto-placement path
// requires) against apiAddr, decoding the full response body.
func startModelAutoPlaced(t *testing.T, client *http.Client, apiAddr, bearerToken, tenantID, model string) (startModelResp, int) {
	t.Helper()
	var resp startModelResp
	status := doJSON(t, client, http.MethodPost, apiAddr, "/v1/tenants/"+tenantID+"/models/"+model+"/start", bearerToken, struct{}{}, &resp)
	return resp, status
}

// TestClusterPlacement_StartWithoutNode_LandsOnNodeWithCapacity is T013
// (quickstart.md Scenario 1): a real 3-node cluster where only node-a
// genuinely has room for the "small" profile (node-b/node-c both report
// tests/fixtures/hw-tiny.json's real, deliberately-insufficient
// capacity) - a start request with no "node" field, sent to node-b
// (which does NOT itself have room, so a successful placement MUST have
// been forwarded), lands on node-a: the response names node-a, and
// node-a's own real dry-run env file for this tenant+model genuinely
// exists on disk.
func TestClusterPlacement_StartWithoutNode_LandsOnNodeWithCapacity(t *testing.T) {
	tc := newTestCluster(t)
	nodeA, adminKeyID, adminKeySecret := tc.bootstrapWithHW("node-a", fixturePath(t, "hw-baseline.json"))
	nodeB, _ := tc.joinWithHW("node-b", nodeA, fixturePath(t, "hw-tiny.json"))
	nodeC, _ := tc.joinWithHW("node-c", nodeA, fixturePath(t, "hw-tiny.json"))
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()

	adminJWT, status := exchangeToken(t, client, nodeA.apiAddr, adminKeyID, adminKeySecret)
	if status != http.StatusOK || adminJWT == "" {
		t.Fatalf("exchange bootstrap admin key for JWT: status=%d, empty=%v", status, adminJWT == "")
	}

	// Register the same tenant+model identically on every real node
	// (this package's established per-node-registry pattern - see this
	// file's package doc comment).
	for _, n := range allNodes {
		if s := createTenant(t, client, n.apiAddr, adminJWT, "tenant-a", "Tenant A"); s != http.StatusOK {
			t.Fatalf("POST /v1/tenants(tenant-a) on node %q: status=%d", n.nodeID, s)
		}
	}
	keyID, keySecret, s := createAPIKey(t, client, nodeA.apiAddr, adminJWT, "tenant-a", []string{"tenant:tenant-a", "model-operator"})
	if s != http.StatusOK {
		t.Fatalf("create tenant-a model-operator API key: status=%d", s)
	}
	tenantJWT, s := exchangeToken(t, client, nodeA.apiAddr, keyID, keySecret)
	if s != http.StatusOK || tenantJWT == "" {
		t.Fatalf("exchange tenant-a API key for JWT: status=%d, empty=%v", s, tenantJWT == "")
	}
	for _, n := range allNodes {
		if s := registerModel(t, client, n.apiAddr, tenantJWT, "tenant-a", "small"); s != http.StatusOK {
			t.Fatalf("POST /v1/tenants/tenant-a/models(small) on node %q: status=%d", n.nodeID, s)
		}
	}

	// Sent to node-b (which does NOT itself have room) - a successful
	// placement here can only mean the request was genuinely evaluated
	// against the real cluster's capacity and (since it must not be
	// node-b or node-c) forwarded to node-a.
	resp, status := startModelAutoPlaced(t, client, nodeB.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("POST start (no node field) to node-b: status=%d, body=%+v", status, resp)
	}
	if resp.Node != "node-a" {
		t.Fatalf("response named node %q, want node-a (the only real node with sufficient capacity)", resp.Node)
	}

	// node-a's own real dry-run env file - the real, tenant-scoped
	// bin/llmctl subprocess side-effect this codebase already uses as its
	// canonical "a real Start() genuinely dispatched" proof
	// (internal/api/routes_models_test.go's identical assertion).
	_, nodeAServicesDir := nodeDryRunEnv(tc.dir, "node-a", "")
	envFile := filepath.Join(nodeAServicesDir, "tenant-a--small.env")
	if _, err := os.Stat(envFile); err != nil {
		t.Fatalf("expected node-a's real tenant-scoped env file %s to exist (proves the forwarded start genuinely dispatched a real subprocess ON NODE-A): %v", envFile, err)
	}

	// Cross-check: node-b and node-c's OWN dry-run services dirs must NOT
	// have this env file - the work genuinely landed on node-a alone, not
	// duplicated anywhere else.
	for _, nodeID := range []string{"node-b", "node-c"} {
		_, svcDir := nodeDryRunEnv(tc.dir, nodeID, "")
		if _, err := os.Stat(filepath.Join(svcDir, "tenant-a--small.env")); err == nil {
			t.Fatalf("node %q's own services dir unexpectedly has the tenant-a--small env file - the work should have landed on node-a alone", nodeID)
		}
	}
}

// TestClusterPlacement_NoNodeHasCapacity_RefusedWithExactShortfall is T014
// (quickstart.md Scenario 2): a real 3-node cluster where EVERY node
// reports tests/fixtures/hw-tiny.json's real, deliberately-insufficient
// capacity - a start request with no "node" field is refused with the
// exact "insufficient_capacity" reason and a "considered" entry per real
// node showing its real (insufficient) capacity, and no node's real
// dry-run state ever shows the profile as started.
func TestClusterPlacement_NoNodeHasCapacity_RefusedWithExactShortfall(t *testing.T) {
	tc := newTestCluster(t)
	tinyFixture := fixturePath(t, "hw-tiny.json")
	nodeA, adminKeyID, adminKeySecret := tc.bootstrapWithHW("node-a", tinyFixture)
	nodeB, _ := tc.joinWithHW("node-b", nodeA, tinyFixture)
	nodeC, _ := tc.joinWithHW("node-c", nodeA, tinyFixture)
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()

	adminJWT, status := exchangeToken(t, client, nodeA.apiAddr, adminKeyID, adminKeySecret)
	if status != http.StatusOK || adminJWT == "" {
		t.Fatalf("exchange bootstrap admin key for JWT: status=%d, empty=%v", status, adminJWT == "")
	}
	for _, n := range allNodes {
		if s := createTenant(t, client, n.apiAddr, adminJWT, "tenant-a", "Tenant A"); s != http.StatusOK {
			t.Fatalf("POST /v1/tenants(tenant-a) on node %q: status=%d", n.nodeID, s)
		}
	}
	keyID, keySecret, s := createAPIKey(t, client, nodeA.apiAddr, adminJWT, "tenant-a", []string{"tenant:tenant-a", "model-operator"})
	if s != http.StatusOK {
		t.Fatalf("create tenant-a model-operator API key: status=%d", s)
	}
	tenantJWT, s := exchangeToken(t, client, nodeA.apiAddr, keyID, keySecret)
	if s != http.StatusOK || tenantJWT == "" {
		t.Fatalf("exchange tenant-a API key for JWT: status=%d, empty=%v", s, tenantJWT == "")
	}
	for _, n := range allNodes {
		if s := registerModel(t, client, n.apiAddr, tenantJWT, "tenant-a", "small"); s != http.StatusOK {
			t.Fatalf("POST /v1/tenants/tenant-a/models(small) on node %q: status=%d", n.nodeID, s)
		}
	}

	resp, status := startModelAutoPlaced(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusServiceUnavailable {
		t.Fatalf("POST start (no node field, no capacity anywhere): status=%d, want 503; body=%+v", status, resp)
	}
	if resp.Error != "insufficient_capacity" {
		t.Fatalf("response error = %q, want %q", resp.Error, "insufficient_capacity")
	}
	if len(resp.Considered) != 3 {
		t.Fatalf("considered = %+v, want exactly 3 entries (one per real cluster node)", resp.Considered)
	}
	for _, c := range resp.Considered {
		// hw-tiny.json's real, hand-verified capacity: 0 real VRAM at all
		// (deliberately GPU-less) - the exact real shortfall every
		// candidate must show.
		if c.Resources.VRAMAvailMB != 0 {
			t.Fatalf("considered node %q reports VRAMAvailMB=%d, want 0 (hw-tiny.json's real, deliberately-insufficient capacity)", c.NodeID, c.Resources.VRAMAvailMB)
		}
	}

	// No node's real dry-run state ever shows the profile as started.
	for _, nodeID := range []string{"node-a", "node-b", "node-c"} {
		_, svcDir := nodeDryRunEnv(tc.dir, nodeID, "")
		if _, err := os.Stat(filepath.Join(svcDir, "tenant-a--small.env")); err == nil {
			t.Fatalf("node %q's real services dir has a tenant-a--small env file despite the refused placement - the refusal must never have dispatched anything, anywhere", nodeID)
		}
	}
}

// --- 002-cluster-model-scheduler Phase 4 (User Story 2, T020/T021) ---

// statusModelResp mirrors the extended GET .../status route's name-only
// JSON response shape (routes_models.go, T023): a list of real,
// per-node status entries - never a single value - so a profile name
// that resolves to more than one real hosting node (spec.md's Edge Case,
// FR-008) is never silently collapsed to one.
type statusModelResp struct {
	Profile   string              `json:"profile"`
	Instances []statusInstanceEnv `json:"instances"`
	Error     string              `json:"error"`
	Reason    string              `json:"reason"`
}

// statusInstanceEnv mirrors one entry of statusModelResp's own Instances
// field - one real node's own live status for the resolved profile.
type statusInstanceEnv struct {
	Node   string `json:"node"`
	Status string `json:"status"`
	Error  string `json:"error"`
}

// statusModelByName calls the extended GET .../status route with NO
// "node" field (marshaled as {} via struct{}{} - the same absent-field
// shape startModelAutoPlaced already establishes for POST .../start),
// resolving purely by profile name via the cluster-wide running-profile
// index (spec.md FR-006).
func statusModelByName(t *testing.T, client *http.Client, apiAddr, bearerToken, tenantID, model string) (statusModelResp, int) {
	t.Helper()
	var resp statusModelResp
	status := doJSON(t, client, http.MethodGet, apiAddr, "/v1/tenants/"+tenantID+"/models/"+model+"/status", bearerToken, struct{}{}, &resp)
	return resp, status
}

// statusModelExplicitNode queries nodeID's own real status directly (the
// byte-identical, pre-Phase-4 explicit-node path) - this file's own
// independent, real-state verification oracle, distinct from the
// name-only route under test.
func statusModelExplicitNode(t *testing.T, client *http.Client, apiAddr, bearerToken, tenantID, model, nodeID string) (string, int) {
	t.Helper()
	var resp struct {
		Status string `json:"status"`
	}
	status := doJSON(t, client, http.MethodGet, apiAddr, "/v1/tenants/"+tenantID+"/models/"+model+"/status", bearerToken, map[string]string{"node": nodeID}, &resp)
	return resp.Status, status
}

// stopModelResp mirrors the extended POST .../stop route's name-only
// JSON response shape (T023): every real node the stop was genuinely
// delivered to, never limited to one (spec.md FR-008/Edge Case).
type stopModelResp struct {
	Status string   `json:"status"`
	Model  string   `json:"model"`
	Nodes  []string `json:"nodes"`
	Error  string   `json:"error"`
	Reason string   `json:"reason"`
}

// stopModelByName calls the extended POST .../stop route with NO "node"
// field.
func stopModelByName(t *testing.T, client *http.Client, apiAddr, bearerToken, tenantID, model string) (stopModelResp, int) {
	t.Helper()
	var resp stopModelResp
	status := doJSON(t, client, http.MethodPost, apiAddr, "/v1/tenants/"+tenantID+"/models/"+model+"/stop", bearerToken, struct{}{}, &resp)
	return resp, status
}

// clusterStatusRunningProfilesResp decodes GET /v1/cluster/status's own
// new top-level running_profiles field (T024) - the minimal shape this
// file's tests need to confirm post-stop cluster-wide state.
type clusterStatusRunningProfilesResp struct {
	RunningProfiles []struct {
		Profile string `json:"profile"`
		NodeID  string `json:"node_id"`
	} `json:"running_profiles"`
}

// containsProfileRow reports whether status (a real bin/llmctl status
// output string, as internal/executor.LocalExecutor.Status filters it -
// header row plus any row whose leftmost column matches) has a
// non-header row whose leftmost (profile) column equals profile -
// mirroring LocalExecutor.Status's own exact filtering logic, so this
// test's oracle is the SAME real field-matching rule that method already
// establishes, not an invented pattern-match.
func containsProfileRow(status, profile string) bool {
	lines := strings.Split(status, "\n")
	for i, line := range lines {
		if i == 0 {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == profile {
			return true
		}
	}
	return false
}

// setUpTenantAndModelOnEveryNode is this file's shared setup extracted
// for Phase 4's tests: mints a bootstrap admin JWT, creates tenant-a
// identically on every real node (this package's own established
// per-node-registry pattern - see this file's package doc comment), and
// registers "small" into tenant-a's namespace identically on every real
// node, returning a real tenant-a model-operator JWT ready to dispatch
// start/stop/status calls.
func setUpTenantAndModelOnEveryNode(t *testing.T, client *http.Client, nodeA *spawnedNode, adminKeyID, adminKeySecret string, allNodes []*spawnedNode) (tenantJWT string) {
	t.Helper()
	adminJWT, status := exchangeToken(t, client, nodeA.apiAddr, adminKeyID, adminKeySecret)
	if status != http.StatusOK || adminJWT == "" {
		t.Fatalf("exchange bootstrap admin key for JWT: status=%d, empty=%v", status, adminJWT == "")
	}
	for _, n := range allNodes {
		if s := createTenant(t, client, n.apiAddr, adminJWT, "tenant-a", "Tenant A"); s != http.StatusOK {
			t.Fatalf("POST /v1/tenants(tenant-a) on node %q: status=%d", n.nodeID, s)
		}
	}
	keyID, keySecret, s := createAPIKey(t, client, nodeA.apiAddr, adminJWT, "tenant-a", []string{"tenant:tenant-a", "model-operator"})
	if s != http.StatusOK {
		t.Fatalf("create tenant-a model-operator API key: status=%d", s)
	}
	tenantJWT, s = exchangeToken(t, client, nodeA.apiAddr, keyID, keySecret)
	if s != http.StatusOK || tenantJWT == "" {
		t.Fatalf("exchange tenant-a API key for JWT: status=%d, empty=%v", s, tenantJWT == "")
	}
	for _, n := range allNodes {
		if s := registerModel(t, client, n.apiAddr, tenantJWT, "tenant-a", "small"); s != http.StatusOK {
			t.Fatalf("POST /v1/tenants/tenant-a/models(small) on node %q: status=%d", n.nodeID, s)
		}
	}
	return tenantJWT
}

// TestClusterPlacement_NameOnlyStatusAndStop_ResolveToRealNode is T020
// (quickstart.md Scenario 3): a profile started automatically (User
// Story 1) lands on a real node the caller never named; a subsequent
// name-only status query AND a name-only stop request - each sent to a
// DIFFERENT real node than the one actually hosting the profile - both
// genuinely resolve to the real hosting node, and GET /v1/cluster/status
// reflects the real post-stop state.
func TestClusterPlacement_NameOnlyStatusAndStop_ResolveToRealNode(t *testing.T) {
	tc := newTestCluster(t)
	nodeA, adminKeyID, adminKeySecret := tc.bootstrapWithHW("node-a", fixturePath(t, "hw-baseline.json"))
	nodeB, _ := tc.joinWithHW("node-b", nodeA, fixturePath(t, "hw-tiny.json"))
	nodeC, _ := tc.joinWithHW("node-c", nodeA, fixturePath(t, "hw-tiny.json"))
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()
	tenantJWT := setUpTenantAndModelOnEveryNode(t, client, nodeA, adminKeyID, adminKeySecret, allNodes)

	// Scenario 1 reused: only node-a has real room, so the profile lands
	// there without this test ever naming it - sent to node-b (which
	// forwards the whole auto-placement decision to the real leader,
	// node-a, exactly like T013).
	startResp, status := startModelAutoPlaced(t, client, nodeB.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("auto-placed start: status=%d, body=%+v", status, startResp)
	}
	if startResp.Node != "node-a" {
		t.Fatalf("start landed on %q, want node-a (the only real node with sufficient capacity)", startResp.Node)
	}

	// Name-only status, sent to node-b - NOT the real host - must
	// genuinely resolve to node-a's real, live status via a real
	// cross-node forward.
	statusResp, status := statusModelByName(t, client, nodeB.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("name-only status (sent to node-b): status=%d, body=%+v", status, statusResp)
	}
	if len(statusResp.Instances) != 1 {
		t.Fatalf("name-only status instances = %+v, want exactly 1 (node-a)", statusResp.Instances)
	}
	if statusResp.Instances[0].Node != "node-a" {
		t.Fatalf("name-only status resolved to node %q, want node-a", statusResp.Instances[0].Node)
	}
	if !containsProfileRow(statusResp.Instances[0].Status, "small") {
		t.Fatalf("name-only status's real status string %q does not show small running on node-a", statusResp.Instances[0].Status)
	}

	// Name-only stop, sent to node-c - NOT the real host, and NOT the
	// real raft leader either (node-a is leader) - so this genuinely
	// exercises the forward-whole-decision-to-the-leader path, exactly
	// like dispatchAutoPlacedStart already does for auto-placed start.
	stopResp, status := stopModelByName(t, client, nodeC.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("name-only stop (sent to node-c): status=%d, body=%+v", status, stopResp)
	}
	if len(stopResp.Nodes) != 1 || stopResp.Nodes[0] != "node-a" {
		t.Fatalf("name-only stop reported nodes=%v, want exactly [node-a]", stopResp.Nodes)
	}

	// node-a's OWN real status (explicit-node path, the pre-existing
	// oracle) no longer shows "small" running - the real subprocess was
	// genuinely stopped, not merely reported stopped.
	realStatus, status := statusModelExplicitNode(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "small", "node-a")
	if status != http.StatusOK {
		t.Fatalf("explicit-node status on node-a: status=%d", status)
	}
	if containsProfileRow(realStatus, "small") {
		t.Fatalf("node-a's real status still shows small running after the name-only stop: %q", realStatus)
	}

	// GET /v1/cluster/status reflects the real post-stop state: no
	// running_profiles entry for "small" anywhere in the cluster.
	var clusterStatus clusterStatusRunningProfilesResp
	if s := doJSON(t, client, http.MethodGet, nodeA.apiAddr, "/v1/cluster/status", "", nil, &clusterStatus); s != http.StatusOK {
		t.Fatalf("GET /v1/cluster/status: status=%d", s)
	}
	for _, rp := range clusterStatus.RunningProfiles {
		if rp.Profile == "small" {
			t.Fatalf("GET /v1/cluster/status still lists a running_profiles entry for small after stop: %+v", clusterStatus.RunningProfiles)
		}
	}
}

// TestClusterPlacement_SameProfileOnMultipleNodes_StopActsOnAll is T021
// (spec.md's Edge Case: "What happens when a profile with the same name
// is already running on more than one node? ... must not silently act
// on only one of them and hide the other - it must report every node
// running it"). Two SEPARATE auto-placed start requests for the SAME
// (tenant, profile) genuinely land on two DIFFERENT real nodes - node-b
// and node-c each advertise tests/fixtures/hw-small-exact.json's real
// capacity, sized to fit EXACTLY one "small" instance (2048MB RAM /
// 3973MB VRAM per bin/llmctl's own real "plan --json" output for a
// GPU-having node, hand-verified) and no more, while node-a (the real
// raft leader, hw-baseline.json) has comfortably more capacity than
// needed but a strictly WORSE (looser) best-fit score, so cluster.Place's
// own real, deterministic best-fit + Node.ID tie-break policy prefers
// node-b then, once node-b's real reservation is exhausted, node-c - a
// real CommandRecordRunningProfile Apply-time re-validation refusal
// (T010) plus the existing retry-once-excluding-the-full-node logic
// (T016) is what makes the second request land somewhere DIFFERENT
// rather than double-booking node-b, exactly as FR-005/SC-004 require. A
// single name-only stop request must then act on BOTH real nodes, never
// silently limiting itself to one.
func TestClusterPlacement_SameProfileOnMultipleNodes_StopActsOnAll(t *testing.T) {
	tc := newTestCluster(t)
	nodeA, adminKeyID, adminKeySecret := tc.bootstrapWithHW("node-a", fixturePath(t, "hw-baseline.json"))
	exactFixture := fixturePath(t, "hw-small-exact.json")
	nodeB, _ := tc.joinWithHW("node-b", nodeA, exactFixture)
	nodeC, _ := tc.joinWithHW("node-c", nodeA, exactFixture)
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()
	tenantJWT := setUpTenantAndModelOnEveryNode(t, client, nodeA, adminKeyID, adminKeySecret, allNodes)

	// First auto-placed start: cluster.Place's best-fit tie-break
	// (ascending Node.ID) picks node-b over the equally-exact-fitting
	// node-c, and over node-a's real-but-loose fit.
	firstResp, status := startModelAutoPlaced(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("first auto-placed start: status=%d, body=%+v", status, firstResp)
	}
	if firstResp.Node != "node-b" {
		t.Fatalf("first start landed on %q, want node-b (the deterministic best-fit tie-break winner)", firstResp.Node)
	}

	// Second auto-placed start for the IDENTICAL (tenant, profile):
	// node-b's real, already-recorded reservation now genuinely refuses
	// a second reservation (T010's Apply-time re-validation), and the
	// existing retry-once-excluding-the-full-node logic (T016) lands
	// this second request on node-c instead - never a double-booking of
	// node-b, and never a refusal (the cluster genuinely has room, just
	// not on the first-tried node).
	secondResp, status := startModelAutoPlaced(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("second auto-placed start: status=%d, body=%+v", status, secondResp)
	}
	if secondResp.Node != "node-c" {
		t.Fatalf("second start landed on %q, want node-c (node-b's real capacity is already fully reserved)", secondResp.Node)
	}

	// Both real nodes' own dry-run env files genuinely exist - proving
	// two REAL, independent subprocess dispatches, not one node running
	// the profile twice or a duplicated audit entry with no real effect.
	for _, nodeID := range []string{"node-b", "node-c"} {
		_, svcDir := nodeDryRunEnv(tc.dir, nodeID, "")
		if _, err := os.Stat(filepath.Join(svcDir, "tenant-a--small.env")); err != nil {
			t.Fatalf("expected node %q's real tenant-scoped env file to exist (proves a real, independent start landed there): %v", nodeID, err)
		}
	}
	// node-a itself was never chosen - no env file there.
	_, nodeASvcDir := nodeDryRunEnv(tc.dir, "node-a", "")
	if _, err := os.Stat(filepath.Join(nodeASvcDir, "tenant-a--small.env")); err == nil {
		t.Fatalf("node-a's own services dir unexpectedly has the tenant-a--small env file - it should never have been chosen (a strictly looser fit than node-b/node-c)")
	}

	// A single name-only stop request, sent to node-a (the real raft
	// leader) - must act on BOTH real hosting nodes, never silently
	// limiting itself to one (spec.md's Edge Case / FR-008).
	stopResp, status := stopModelByName(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("name-only stop: status=%d, body=%+v", status, stopResp)
	}
	gotNodes := append([]string(nil), stopResp.Nodes...)
	sortStringsAsc(gotNodes)
	wantNodes := []string{"node-b", "node-c"}
	if len(gotNodes) != len(wantNodes) || gotNodes[0] != wantNodes[0] || gotNodes[1] != wantNodes[1] {
		t.Fatalf("name-only stop reported nodes=%v, want exactly %v (never silently limited to one)", stopResp.Nodes, wantNodes)
	}

	// Both real nodes' own explicit-node status confirms "small" is
	// genuinely no longer running - the stop was really delivered to
	// both, not merely reported as delivered to both.
	for _, nodeID := range []string{"node-b", "node-c"} {
		realStatus, status := statusModelExplicitNode(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "small", nodeID)
		if status != http.StatusOK {
			t.Fatalf("explicit-node status on %q: status=%d", nodeID, status)
		}
		if containsProfileRow(realStatus, "small") {
			t.Fatalf("node %q's real status still shows small running after the name-only stop: %q", nodeID, realStatus)
		}
	}

	// GET /v1/cluster/status reflects the real post-stop state: zero
	// running_profiles entries for "small" anywhere.
	var clusterStatus clusterStatusRunningProfilesResp
	if s := doJSON(t, client, http.MethodGet, nodeA.apiAddr, "/v1/cluster/status", "", nil, &clusterStatus); s != http.StatusOK {
		t.Fatalf("GET /v1/cluster/status: status=%d", s)
	}
	for _, rp := range clusterStatus.RunningProfiles {
		if rp.Profile == "small" {
			t.Fatalf("GET /v1/cluster/status still lists a running_profiles entry for small after stop: %+v", clusterStatus.RunningProfiles)
		}
	}
}

// sortStringsAsc is a tiny local insertion sort over the 2-element slice
// T021's own assertion needs - this file's tests never need a
// general-purpose sort for more than the 2 real node IDs asserted on
// there, so pulling in "sort" for a single call site is unnecessary
// indirection.
func sortStringsAsc(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j-1] > s[j]; j-- {
			s[j-1], s[j] = s[j], s[j-1]
		}
	}
}

// --- 002-cluster-model-scheduler Phase 5 (User Story 3, T026/T027) ---
//
// This phase reuses multitenancy_isolation_test.go's own
// auditEntry/auditEntries helpers (this package's ALREADY-ESTABLISHED
// GET /v1/audit/entries envelope + fetch helper) rather than redefining
// a second, duplicate audit-entry mirror type here.

// placementDecisionNodeSnapshotEnv mirrors ONE entry of
// cluster.PlacementDecision's ConsideredNodes field -
// cluster.NodeCapacitySnapshot's real JSON shape (data-model.md's
// NodeCapacitySnapshot entity, "a point-in-time copy ... of exactly what
// was true when the decision was made").
type placementDecisionNodeSnapshotEnv struct {
	NodeID    string `json:"node_id"`
	Resources struct {
		RAMAvailMB  int64 `json:"ram_avail_mb"`
		VRAMAvailMB int64 `json:"vram_avail_mb"`
	} `json:"resources"`
}

// placementDecisionEnv mirrors cluster.PlacementDecision's real JSON
// shape in full (data-model.md's PlacementDecision entity: Profile,
// ChosenNodeID, ConsideredNodes, Reason, DecidedAt) - the value T027
// decodes internal/audit.Entry's own Decision field (itself a raw,
// pre-serialized JSON string per routes_models.go's
// recordPlacementDecision) into.
type placementDecisionEnv struct {
	Profile         string                             `json:"profile"`
	ChosenNodeID    string                             `json:"chosen_node_id"`
	ConsideredNodes []placementDecisionNodeSnapshotEnv `json:"considered_nodes"`
	Reason          string                             `json:"reason"`
	DecidedAt       time.Time                          `json:"decided_at"`
}

// fetchLastPlacementDecision fetches GET /v1/audit/entries from apiAddr
// (admin-only, routes_audit.go) via this package's own established
// auditEntries helper (multitenancy_isolation_test.go), authenticated as
// adminBearerToken, and decodes the LAST "placement_decision" audit
// entry recorded for profile - internal/audit/log.go's existing,
// already-wired read path (T018's own recordPlacementDecision write
// path, T074's pre-existing admin-only GET /v1/audit/entries read
// route) - fatally failing the test if none is found or the entry's own
// Decision field does not decode as a real, well-formed
// cluster.PlacementDecision.
func fetchLastPlacementDecision(t *testing.T, client *http.Client, apiAddr, adminBearerToken, profile string) placementDecisionEnv {
	t.Helper()

	entries := auditEntries(t, client, apiAddr, adminBearerToken)
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		if e.Action != "placement_decision" || e.Resource != profile {
			continue
		}
		var decision placementDecisionEnv
		if err := json.Unmarshal([]byte(e.Decision), &decision); err != nil {
			t.Fatalf("decode placement_decision audit entry's Decision field %q for profile %q: %v", e.Decision, profile, err)
		}
		return decision
	}
	t.Fatalf("no placement_decision audit entry for profile %q found among %d real audit entries on %s", profile, len(entries), apiAddr)
	return placementDecisionEnv{} // unreachable - t.Fatalf calls runtime.Goexit()
}

// TestClusterPlacement_ConcurrentStarts_NeverDoubleBookANode is T026
// (quickstart.md Scenario 4): two DIFFERENT profiles are sized, via
// three real, deliberately non-overlapping hardware fixtures, so
// exactly ONE real node has room for each and NEITHER fits on the
// third - "small" (a GPU-mode profile; real footprint per
// `bin/llmctl plan --json` against node-a's own hw-baseline.json,
// hand-verified: ram_mb=2048 vram_mb=3973) only fits on node-b
// (tests/fixtures/hw-small-exact.json: real raw memory.available_mb=
// 8192, gpu_total_vram_mb=5000, per `bin/llmctl hw --json`), and
// "moe-fast" (a CPU-mode profile EVEN on a GPU-having node - hand-
// verified via the same real `plan --json` call: ram_mb=15644
// vram_mb=0) only fits on node-c (tests/fixtures/hw-cpu-heavy.json,
// this task's own new fixture: real raw memory.available_mb=20000,
// gpu_total_vram_mb=0). Both profiles' resource footprints are always
// computed against node-a's OWN real hardware (routes_models.go's
// dispatchAutoPlacedStart calls base.Footprint on whichever node is the
// real Raft leader, and node-a is bootstrapped as leader here), so both
// footprints stay fixed for the whole test regardless of which real
// node a request is sent to.
//
// node-a itself (hw-baseline.json: raw available_mb=30000,
// gpu_total_vram_mb=12288) DOES have enough raw capacity for BOTH
// profiles too, but cluster.Place's best-fit bin-packing policy
// (placement.go's leftoverScore doc comment: "packs workloads into
// nodes that already have the least slack") always prefers node-b's/
// node-c's much tighter real fit over node-a's much looser one -
// hand-verified by computing leftoverScore for all three real
// candidates against both real footprints before writing this test,
// never invented numbers. Neither profile ever fits node-b's/node-c's
// OWN insufficient dimension (node-b's real VRAM budget is
// insufficient for "moe-fast"'s RAM need; node-c's real zero VRAM is
// insufficient for "small"'s VRAM need), so this is a genuine,
// hardware-real 3-way exclusion, not a coincidence of best-fit scoring
// alone.
//
// Two real goroutines fire real concurrent HTTP start requests DIRECTLY
// at node-a (the real Raft leader) - so both requests genuinely race
// INSIDE the same leader process's dispatchAutoPlacedStart / cluster.
// Place / node.RecordRunningProfile call path, the exact FR-005/SC-004
// TOCTOU surface T009/T010 (already merged, Phase 2) close. Repeated for
// 10 iterations (Constitution Â§11.4.50's deterministic-consistency
// discipline for a concurrency-sensitive test - ruling out a lucky
// single pass), each iteration starting both profiles concurrently,
// asserting both land on their correct respective real node and never
// both on the same one, confirming two REAL independent dry-run
// subprocess dispatches genuinely happened (not merely reported), then
// stopping both (freeing each real node's reservation) before the next
// iteration's concurrent pair fires.
func TestClusterPlacement_ConcurrentStarts_NeverDoubleBookANode(t *testing.T) {
	tc := newTestCluster(t)
	nodeA, adminKeyID, adminKeySecret := tc.bootstrapWithHW("node-a", fixturePath(t, "hw-baseline.json"))
	nodeB, _ := tc.joinWithHW("node-b", nodeA, fixturePath(t, "hw-small-exact.json"))
	nodeC, _ := tc.joinWithHW("node-c", nodeA, fixturePath(t, "hw-cpu-heavy.json"))
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()
	tenantJWT := setUpTenantAndModelOnEveryNode(t, client, nodeA, adminKeyID, adminKeySecret, allNodes)
	for _, n := range allNodes {
		if s := registerModel(t, client, n.apiAddr, tenantJWT, "tenant-a", "moe-fast"); s != http.StatusOK {
			t.Fatalf("POST /v1/tenants/tenant-a/models(moe-fast) on node %q: status=%d", n.nodeID, s)
		}
	}

	// Root-caused 2026-09-23: this test's own concurrent auto-placed start
	// calls genuinely race real Raft leader election + leader-forwarding +
	// the placement decision + a real dry-run subprocess dispatch, all
	// within a single client-side round trip - tc.httpClient()'s default
	// 5s Timeout is the SAME class of too-tight-under-real-load timeout
	// replication_health_test.go's own longClient override already exists
	// to fix (see that file's header comment on the identical pattern);
	// confirmed by hand: this test fails deterministically (not merely
	// flakily) on a host under real, persistent background CPU contention
	// (a co-resident process pegged near 100% CPU throughout), with the
	// client returning "context deadline exceeded (Client.Timeout exceeded
	// while awaiting headers)" at iteration 0 every time - not a placement
	// logic bug, a too-tight client timeout for genuinely real load. A
	// dedicated, longer-timeout client (sharing the SAME real mTLS
	// transport, exactly like replication_health_test.go's longClient) is
	// used for these two calls only, so this test's own client never times
	// out before the real, bounded (never indefinite) election/forwarding
	// genuinely completes.
	longClient := &http.Client{Transport: client.Transport, Timeout: 30 * time.Second}
	const iterations = 10
	for iter := 0; iter < iterations; iter++ {
		var wg sync.WaitGroup
		var smallResp, moeResp startModelResp
		var smallStatus, moeStatus int
		wg.Add(2)
		go func() {
			defer wg.Done()
			smallResp, smallStatus = startModelAutoPlaced(t, longClient, nodeA.apiAddr, tenantJWT, "tenant-a", "small")
		}()
		go func() {
			defer wg.Done()
			moeResp, moeStatus = startModelAutoPlaced(t, longClient, nodeA.apiAddr, tenantJWT, "tenant-a", "moe-fast")
		}()
		wg.Wait()

		if smallStatus != http.StatusOK {
			t.Fatalf("iteration %d: concurrent auto-placed start of \"small\": status=%d, body=%+v", iter, smallStatus, smallResp)
		}
		if moeStatus != http.StatusOK {
			t.Fatalf("iteration %d: concurrent auto-placed start of \"moe-fast\": status=%d, body=%+v", iter, moeStatus, moeResp)
		}
		if smallResp.Node != "node-b" {
			t.Fatalf("iteration %d: \"small\" landed on %q, want node-b (the only real node with room for it)", iter, smallResp.Node)
		}
		if moeResp.Node != "node-c" {
			t.Fatalf("iteration %d: \"moe-fast\" landed on %q, want node-c (the only real node with room for it)", iter, moeResp.Node)
		}
		if smallResp.Node == moeResp.Node {
			t.Fatalf("iteration %d: both profiles landed on the SAME real node %q - double-booked", iter, smallResp.Node)
		}

		// Both real nodes' own dry-run env files genuinely exist - proving
		// two REAL, independent subprocess dispatches actually happened
		// THIS iteration, never merely a reported success.
		_, svcDirB := nodeDryRunEnv(tc.dir, "node-b", "")
		if _, err := os.Stat(filepath.Join(svcDirB, "tenant-a--small.env")); err != nil {
			t.Fatalf("iteration %d: expected node-b's real tenant-scoped env file to exist (proves a real start genuinely dispatched ON NODE-B): %v", iter, err)
		}
		_, svcDirC := nodeDryRunEnv(tc.dir, "node-c", "")
		if _, err := os.Stat(filepath.Join(svcDirC, "tenant-a--moe-fast.env")); err != nil {
			t.Fatalf("iteration %d: expected node-c's real tenant-scoped env file to exist (proves a real start genuinely dispatched ON NODE-C): %v", iter, err)
		}

		// Free both real reservations before the next iteration's
		// concurrent pair fires - this file's established name-only stop
		// path (T023, already exercised sequentially by T020/T021).
		stopSmall, s := stopModelByName(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "small")
		if s != http.StatusOK || len(stopSmall.Nodes) != 1 || stopSmall.Nodes[0] != "node-b" {
			t.Fatalf("iteration %d: stop \"small\": status=%d, body=%+v", iter, s, stopSmall)
		}
		stopMoe, s := stopModelByName(t, client, nodeA.apiAddr, tenantJWT, "tenant-a", "moe-fast")
		if s != http.StatusOK || len(stopMoe.Nodes) != 1 || stopMoe.Nodes[0] != "node-c" {
			t.Fatalf("iteration %d: stop \"moe-fast\": status=%d, body=%+v", iter, s, stopMoe)
		}
	}
}

// TestClusterPlacement_DecisionIsReconstructableAfterTheFact is T027
// (quickstart.md Scenario 5): after a real automatic placement (reusing
// Scenario 1's exact setup - only node-a genuinely has room for
// "small"), the resulting PlacementDecision audit record - fetched via
// internal/audit/log.go's EXISTING GET /v1/audit/entries read path
// (routes_audit.go, admin-only; already wired into every real node
// process via cmd/llmctld/main.go's api.RegisterAuditRoutes call) on
// node-a specifically (the real Raft leader that actually made the
// decision - audit.Log is per-process, NEVER Raft-replicated, per
// data-model.md's own "Concurrency-safety note (FR-005, SC-004)"
// section: "PlacementDecision records are NOT part of the Raft-
// replicated ClusterState") - names the real chosen node, every real
// considered node's real advertised capacity AT DECISION TIME, and a
// human-readable reason: fully reconstructable purely from this ONE
// audit record, without querying any node's LIVE state (quickstart.md
// Scenario 5's own expected result).
func TestClusterPlacement_DecisionIsReconstructableAfterTheFact(t *testing.T) {
	tc := newTestCluster(t)
	nodeA, adminKeyID, adminKeySecret := tc.bootstrapWithHW("node-a", fixturePath(t, "hw-baseline.json"))
	nodeB, _ := tc.joinWithHW("node-b", nodeA, fixturePath(t, "hw-tiny.json"))
	nodeC, _ := tc.joinWithHW("node-c", nodeA, fixturePath(t, "hw-tiny.json"))
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()
	tenantJWT := setUpTenantAndModelOnEveryNode(t, client, nodeA, adminKeyID, adminKeySecret, allNodes)

	decideBefore := time.Now()
	startResp, status := startModelAutoPlaced(t, client, nodeB.apiAddr, tenantJWT, "tenant-a", "small")
	if status != http.StatusOK {
		t.Fatalf("auto-placed start: status=%d, body=%+v", status, startResp)
	}
	if startResp.Node != "node-a" {
		t.Fatalf("start landed on %q, want node-a (the only real node with sufficient capacity)", startResp.Node)
	}
	decideAfter := time.Now()

	// The decision was made ON node-a (the real leader) - audit.Log is
	// per-process, so the audit trail for THIS decision exists only on
	// node-a; a real admin JWT is required (routes_audit.go's
	// requireAuditAccess: ActionTenantManage, granted by RoleAdmin).
	adminJWT, status := exchangeToken(t, client, nodeA.apiAddr, adminKeyID, adminKeySecret)
	if status != http.StatusOK || adminJWT == "" {
		t.Fatalf("exchange bootstrap admin key for JWT: status=%d, empty=%v", status, adminJWT == "")
	}

	decision := fetchLastPlacementDecision(t, client, nodeA.apiAddr, adminJWT, "small")

	// Every field data-model.md's PlacementDecision entity specifies -
	// reconstructed purely from this ONE audit record.
	if decision.Profile != "small" {
		t.Fatalf("decision.Profile = %q, want \"small\"", decision.Profile)
	}
	if decision.ChosenNodeID != "node-a" {
		t.Fatalf("decision.ChosenNodeID = %q, want \"node-a\" (the real chosen node)", decision.ChosenNodeID)
	}
	if decision.Reason != "placed" {
		t.Fatalf("decision.Reason = %q, want \"placed\" (the real success reason routes_models.go's recordPlacementDecision records)", decision.Reason)
	}
	if decision.DecidedAt.Before(decideBefore) || decision.DecidedAt.After(decideAfter) {
		t.Fatalf("decision.DecidedAt = %v, want between %v and %v (the real wall-clock window the placement actually happened in)", decision.DecidedAt, decideBefore, decideAfter)
	}

	// Every real candidate node's real advertised capacity AT DECISION
	// TIME - hw-baseline.json's/hw-tiny.json's own real, hand-verified
	// raw memory.available_mb/gpu_total_vram_mb values (cmd/llmctld/
	// hardware_probe.go maps those RAW hw-probe fields directly onto
	// cluster.Resources, never `bin/llmctl plan --json`'s separately-
	// computed per-profile "budget" figure - confirmed by reading
	// probeLocalResources's own doc comment before writing this
	// assertion), sorted by ascending NodeID (routes_models.go's
	// nodeCapacitySnapshots).
	wantByNode := map[string]struct{ ram, vram int64 }{
		"node-a": {30000, 12288}, // hw-baseline.json: available_mb=30000, gpu_total_vram_mb=12288
		"node-b": {1500, 0},      // hw-tiny.json: available_mb=1500, gpu_total_vram_mb=0
		"node-c": {1500, 0},      // hw-tiny.json (same fixture as node-b)
	}
	if len(decision.ConsideredNodes) != 3 {
		t.Fatalf("decision.ConsideredNodes = %+v, want exactly 3 entries (every real cluster node)", decision.ConsideredNodes)
	}
	prevNodeID := ""
	for _, cn := range decision.ConsideredNodes {
		if cn.NodeID <= prevNodeID {
			t.Fatalf("decision.ConsideredNodes not sorted by ascending NodeID: %+v", decision.ConsideredNodes)
		}
		prevNodeID = cn.NodeID
		want, known := wantByNode[cn.NodeID]
		if !known {
			t.Fatalf("decision.ConsideredNodes has unexpected NodeID %q", cn.NodeID)
		}
		if cn.Resources.RAMAvailMB != want.ram || cn.Resources.VRAMAvailMB != want.vram {
			t.Fatalf("decision.ConsideredNodes[%q] = ram=%d vram=%d, want ram=%d vram=%d (the real advertised capacity at decision time)",
				cn.NodeID, cn.Resources.RAMAvailMB, cn.Resources.VRAMAvailMB, want.ram, want.vram)
		}
	}
}
