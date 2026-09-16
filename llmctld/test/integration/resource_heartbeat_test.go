// Package integration (resource_heartbeat_test.go): T072-FU6's own real
// end-to-end proof that the 002-cluster-model-scheduler resource-
// freshness heartbeat (internal/cluster/health.go's Monitor.
// SetResourceReporting) genuinely has a live caller now - the EXACT gap
// docs/CONTINUATION.md §10f/§10h and specs/001-llmctl-completion/
// tasks.md's T072-FU6 entry disclosed: the mechanism was fully
// implemented and unit-tested (health_test.go's own
// TestMonitor_PeriodicTick_SubmitsResourceUpdate) but cmd/llmctld/main.go
// never constructed a cluster.Monitor for any purpose, so a running
// node's advertised Resources went stale forever after join.
//
// Reuses cluster_placement_test.go's LLMCTL_FAKE_HW fixture mechanism
// (bootstrapWithHW/joinWithHW/nodeDryRunEnv) - the SAME real bin/llmctl
// subprocess this test's node-under-test shells out to on every real
// Monitor tick (cmd/llmctld's own probeLocalResources, wired as the
// Monitor's ResourceSource) re-reads whatever LLMCTL_FAKE_HW currently
// points at FRESH on every invocation (lib/hardware.sh's hw_probe_json:
// `cat "${LLMCTL_FAKE_HW}"`, never cached in-process) - so REWRITING that
// fixture file's real bytes on disk mid-test, with no process restart,
// is the real, non-mocked mechanism this test uses to make a node's
// real reported capacity genuinely change over time.
package integration

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// clusterStatusNodeResources mirrors GET /v1/cluster/status's real JSON
// response closely enough to read state.nodes[nodeID].resources.ram_avail_mb -
// a plain, decoupled local type matching this package's own established
// duplication-over-shared-type-mutation discipline (failover_state_test.go's
// replAppendEntry/replKVState doc comment; the sibling
// clusterStatusReplicationRoles type in that same file reads a different
// nested path off the SAME real endpoint for a different concern).
type clusterStatusNodeResources struct {
	IsLeader bool `json:"is_leader"`
	State    struct {
		Nodes map[string]struct {
			Resources struct {
				RAMAvailMB int64 `json:"ram_avail_mb"`
			} `json:"resources"`
		} `json:"nodes"`
	} `json:"state"`
}

// getNodeRAMAvailMB GETs apiAddr's real /v1/cluster/status route (no JWT
// required - mTLS-only, routes_cluster.go) and returns nodeID's currently
// cluster-replicated RAMAvailMB, or ok=false if apiAddr's own request
// failed or nodeID has no entry yet.
func getNodeRAMAvailMB(t *testing.T, client *http.Client, apiAddr, nodeID string) (ramAvailMB int64, ok bool) {
	t.Helper()
	var resp clusterStatusNodeResources
	status := doJSON(t, client, http.MethodGet, apiAddr, "/v1/cluster/status", "", nil, &resp)
	if status != http.StatusOK {
		return 0, false
	}
	n, ok := resp.State.Nodes[nodeID]
	if !ok {
		return 0, false
	}
	return n.Resources.RAMAvailMB, true
}

// hwFixtureDoc mirrors the real hw_probe_json schema tests/fixtures/
// hw-baseline.json already uses (this file's own package doc comment:
// lib/hardware.sh's LLMCTL_FAKE_HW path just `cat`s whatever real file is
// at that path, so this test writes the SAME real shape rather than
// inventing a new, untested-against-the-real-shell-script one) - a plain,
// decoupled local type built via encoding/json.Marshal (never hand-built
// string concatenation), matching cmd/llmctld/hardware_probe.go's own
// hwProbeDoc parsing side for the subset fields that round-trip.
type hwFixtureDoc struct {
	OS   string `json:"os"`
	Arch string `json:"arch"`
	CPU  struct {
		Cores        int      `json:"cores"`
		Model        string   `json:"model"`
		Arch         string   `json:"arch"`
		SIMD         []string `json:"simd"`
		AppleSilicon bool     `json:"apple_silicon"`
		AppleChip    *string  `json:"apple_chip"`
	} `json:"cpu"`
	Memory struct {
		TotalMB     int64 `json:"total_mb"`
		AvailableMB int64 `json:"available_mb"`
	} `json:"memory"`
	GPUs           []any `json:"gpus"`
	GPUTotalVRAMMB int64 `json:"gpu_total_vram_mb"`
	Storage        struct {
		Path   string `json:"path"`
		FreeMB int64  `json:"free_mb"`
		Type   string `json:"type"`
	} `json:"storage"`
}

// writeHWFixture writes a real, valid hw_probe_json-shaped fixture to
// path reporting ramAvailMB as memory.available_mb.
func writeHWFixture(t *testing.T, path string, cpuCores int, ramAvailMB int64) {
	t.Helper()
	doc := hwFixtureDoc{OS: "linux", Arch: "x86_64"}
	doc.CPU.Cores = cpuCores
	doc.CPU.Model = "test-fixture-cpu"
	doc.CPU.Arch = "x86_64"
	doc.CPU.SIMD = []string{"sse4_2"}
	doc.Memory.TotalMB = 65536
	doc.Memory.AvailableMB = ramAvailMB
	doc.GPUs = []any{}
	doc.Storage.Path = "/tmp/llmctl-test-models"
	doc.Storage.FreeMB = 100000
	doc.Storage.Type = "ssd"

	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal hw fixture: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write hw fixture %s: %v", path, err)
	}
}

// resourceHeartbeatWaitTimeout bounds how long this test waits for a real
// cluster.Monitor tick to re-probe + durably resubmit a node's changed
// Resources, and for that update to become visible on a DIFFERENT real
// node's own /v1/cluster/status - generous relative to the real cadence
// this proof depends on (cmd/llmctld's main.go wireHealthMonitor: a
// nodeRegistrySyncInterval (1s) freshness bound is irrelevant to THIS
// mechanism - SetResourceReporting's own reportResources fires on every
// cluster.DefaultHealthCheckInterval (10s) tick unconditionally, see
// health.go's Start() - so one full 10s tick plus Raft-replication
// latency plus scheduling jitter, matching failover_state_test.go's own
// replicationRoleReassignmentTimeout's identical "generous but bounded"
// reasoning for the sibling T072-FU7 mechanism).
const resourceHeartbeatWaitTimeout = 30 * time.Second

// TestResourceHeartbeat_ChangedCapacityPropagatesWithoutRestart is
// T072-FU6's own real end-to-end proof: a real 2-node cluster, node-a's
// real bin/llmctl subprocess reporting a fixture-controlled RAM capacity
// via LLMCTL_FAKE_HW, the fixture's real on-disk bytes REWRITTEN mid-test
// (no process restart, no config reload, no signal) to a different real
// value, and node-b - a DIFFERENT real process, never node-a itself -
// observing the change via its own real, independently-authenticated
// GET /v1/cluster/status call within one real Monitor health-check tick.
// Before this fix, node-a's own advertised Resources would have stayed
// at whatever join-time probeLocalResources happened to read, forever -
// the exact "resource-freshness heartbeat ... has zero non-test callers"
// gap this test exists to close.
func TestResourceHeartbeat_ChangedCapacityPropagatesWithoutRestart(t *testing.T) {
	tc := newTestCluster(t)

	hwPath := filepath.Join(t.TempDir(), "hw-node-a.json")
	const baselineRAMAvailMB = int64(30000)
	writeHWFixture(t, hwPath, 8, baselineRAMAvailMB)

	nodeA, _, _ := tc.bootstrapWithHW("node-a", hwPath)
	nodeB, _ := tc.joinWithHW("node-b", nodeA, fixturePath(t, "hw-tiny.json"))
	allNodes := []*spawnedNode{nodeA, nodeB}

	client := tc.httpClient()

	deadline := time.Now().Add(5 * time.Second)
	for _, n := range allNodes {
		for {
			nodes, err := tc.getNodes(client, n.apiAddr)
			if err == nil && len(nodes.Servers) == 2 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full 2-node configuration before the test began", n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	// Baseline: node-a's own join/bootstrap-time RegisterSelf call already
	// probed hwPath once (before this test rewrites it), so node-B - a
	// DIFFERENT real process - should already see node-a's baseline value
	// via Raft replication, independent of any Monitor tick at all. This
	// establishes the precondition the later "changed" assertion depends
	// on: if this baseline check fails, the defect is in join-time
	// registration, not in the heartbeat this test targets.
	baselineDeadline := time.Now().Add(5 * time.Second)
	for {
		got, ok := getNodeRAMAvailMB(t, client, nodeB.apiAddr, "node-a")
		if ok && got == baselineRAMAvailMB {
			break
		}
		if time.Now().After(baselineDeadline) {
			got, _ := getNodeRAMAvailMB(t, client, nodeB.apiAddr, "node-a")
			t.Fatalf("precondition failed: node-b never observed node-a's baseline RAMAvailMB=%d within 5s (last observed: %d)", baselineRAMAvailMB, got)
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Logf("baseline confirmed: node-b observes node-a's RAMAvailMB=%d via join-time registration", baselineRAMAvailMB)

	// Rewrite the SAME fixture file's real bytes on disk - node-a's real
	// bin/llmctl subprocess re-reads this file FRESH on its next real
	// `hw --json` invocation (this file's own package doc comment); no
	// signal, no restart, no config reload is sent to node-a's process.
	const changedRAMAvailMB = int64(12345)
	writeHWFixture(t, hwPath, 8, changedRAMAvailMB)
	rewroteAt := time.Now()
	t.Logf("rewrote %s on disk to report RAMAvailMB=%d; waiting for node-a's own real Monitor tick to re-probe + resubmit it", hwPath, changedRAMAvailMB)

	// The load-bearing wait: poll node-b's own real /v1/cluster/status -
	// NEVER node-a's own, so this genuinely proves cluster-wide Raft
	// replication of the update, not merely a local in-memory read on the
	// same process that produced it - until the changed value is visible.
	changeDeadline := time.Now().Add(resourceHeartbeatWaitTimeout)
	for {
		got, ok := getNodeRAMAvailMB(t, client, nodeB.apiAddr, "node-a")
		if ok && got == changedRAMAvailMB {
			break
		}
		if time.Now().After(changeDeadline) {
			t.Fatalf("T072-FU6 REGRESSION: node-b never observed node-a's changed RAMAvailMB=%d within %s of rewriting %s (last observed: %d) - cluster.Monitor's resource-freshness heartbeat did not fire (or did not commit/replicate)", changedRAMAvailMB, resourceHeartbeatWaitTimeout, hwPath, got)
		}
		time.Sleep(200 * time.Millisecond)
	}
	elapsed := time.Since(rewroteAt)
	t.Logf("SUCCESS: node-b observed node-a's changed RAMAvailMB=%d (from %d) %s after the fixture rewrite, via cluster.Monitor's real HTTP-free local re-probe + Raft-committed CommandUpdateResources - T072-FU6's disclosed gap is closed", changedRAMAvailMB, baselineRAMAvailMB, elapsed)
}
