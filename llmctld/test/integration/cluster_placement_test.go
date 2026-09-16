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
	"net/http"
	"os"
	"path/filepath"
	"testing"

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
