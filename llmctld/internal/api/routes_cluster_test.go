// Package api (routes_cluster_test.go): 002-cluster-model-scheduler T022
// - proves GET /v1/cluster/status's extended response (T024) genuinely
// exposes ClusterState.RunningProfiles as a TOP-LEVEL "running_profiles"
// field (contracts/cluster-model-api.md: "Response gains a
// running_profiles field ... in addition to the existing
// is_leader/state fields"), populated via a real
// CommandRecordRunningProfile Apply - the SAME real Raft write path
// dispatchAutoPlacedStart (routes_models.go, T016) uses - never a
// hand-built cluster.RunningProfile literal read back without going
// through Apply at all.
package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// newClusterRoutesTestNode boots a real, single-node raft.Node (mirroring
// routes_models_test.go's own newModelRoutesTestEngineWithNode bootstrap
// sequence exactly - same real mTLS CA, same real Bootstrap + RegisterSelf
// + waitForRealLeader pattern) and wires RegisterClusterRoutes onto a
// fresh *gin.Engine, with no RequireMTLS middleware applied (this test
// calls the handler directly via httptest, matching how
// newModelRoutesTestEngine's own tests never re-exercise the transport
// layer either) - it exists purely to prove the extended GET
// /v1/cluster/status handler itself, not the mTLS enforcement wrapper
// server.go already covers separately.
func newClusterRoutesTestNode(t *testing.T) (engine *gin.Engine, node *raft.Node) {
	t.Helper()
	gin.SetMode(gin.TestMode)

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

	if err := node.RegisterSelf("127.0.0.1:0", cluster.Resources{
		CPUCores: 8, RAMTotalMB: 16384, RAMAvailMB: 8192,
		VRAMTotalMB: 8192, VRAMAvailMB: 8192, NetworkMbps: 1000,
	}); err != nil {
		t.Fatalf("RegisterSelf: %v", err)
	}

	engine = gin.New()
	RegisterClusterRoutes(engine, node)
	return engine, node
}

// clusterStatusResp mirrors GET /v1/cluster/status's own extended JSON
// response shape - the exact three top-level fields the contract
// requires: the pre-existing is_leader/state pair (T058), plus the new
// running_profiles field (T024) this test exists to prove.
type clusterStatusResp struct {
	IsLeader        bool                     `json:"is_leader"`
	State           json.RawMessage          `json:"state"`
	RunningProfiles []cluster.RunningProfile `json:"running_profiles"`
}

// TestClusterStatus_IncludesRunningProfilesFromRealClusterState proves a
// real CommandRecordRunningProfile Apply against a real bootstrapped
// node's ClusterState is genuinely reflected in GET /v1/cluster/status's
// own top-level running_profiles field - not merely nested inside its
// pre-existing "state" field, which contracts/cluster-model-api.md
// explicitly requires exposed IN ADDITION TO, never as a substitute for.
func TestClusterStatus_IncludesRunningProfilesFromRealClusterState(t *testing.T) {
	engine, node := newClusterRoutesTestNode(t)

	footprint := cluster.PlacementRequest{RAMMB: 2048, VRAMMB: 3973}
	if err := node.RecordRunningProfile("small", "tenant-a", "node-a", footprint); err != nil {
		t.Fatalf("RecordRunningProfile: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/cluster/status", nil)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /v1/cluster/status: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp clusterStatusResp
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response %q: %v", rec.Body.String(), err)
	}

	if len(resp.RunningProfiles) != 1 {
		t.Fatalf("running_profiles = %+v, want exactly 1 entry (the one real CommandRecordRunningProfile Apply above)", resp.RunningProfiles)
	}
	got := resp.RunningProfiles[0]
	if got.Profile != "small" || got.TenantID != "tenant-a" || got.NodeID != "node-a" {
		t.Fatalf("running_profiles[0] = %+v, want {Profile:small TenantID:tenant-a NodeID:node-a ...}", got)
	}
	if got.Footprint.RAMMB != 2048 || got.Footprint.VRAMMB != 3973 {
		t.Fatalf("running_profiles[0].Footprint = %+v, want {RAMMB:2048 VRAMMB:3973}", got.Footprint)
	}

	// The pre-existing is_leader/state pair (T058) must still be present
	// unchanged - this is an EXTENSION, never a replacement.
	if !resp.IsLeader {
		t.Fatalf("is_leader = false, want true (this is the only, self-elected node in a real single-node bootstrap)")
	}
	if len(resp.State) == 0 {
		t.Fatalf("state field is empty/absent - the pre-existing response field must be preserved")
	}
}

// TestClusterStatus_RunningProfilesEmptyArrayWhenNoneRecorded proves the
// new running_profiles field is always PRESENT as an empty array (never
// omitted, never null) when nothing has been recorded yet - so a caller
// can always safely range over it without a nil-check, matching
// cluster.NewClusterState's own "RunningProfiles: []RunningProfile{}"
// non-nil-empty-slice discipline.
func TestClusterStatus_RunningProfilesEmptyArrayWhenNoneRecorded(t *testing.T) {
	engine, _ := newClusterRoutesTestNode(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/cluster/status", nil)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /v1/cluster/status: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	// Deliberately unmarshal into a raw map first so this test can tell
	// the difference between "the key is present with an empty array"
	// and "the key is entirely absent" (both would decode a typed
	// []cluster.RunningProfile field to its nil zero value, which is NOT
	// the distinction this test needs to make).
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("unmarshal response %q: %v", rec.Body.String(), err)
	}
	rp, present := raw["running_profiles"]
	if !present {
		t.Fatalf("response %q has no top-level running_profiles key at all", rec.Body.String())
	}
	if string(rp) != "[]" {
		t.Fatalf("running_profiles = %s, want the literal empty JSON array [] (no profile recorded)", rp)
	}
}
