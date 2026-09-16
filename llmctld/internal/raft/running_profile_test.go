package raft

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// TestRecordRunningProfile_ReservesRealCapacityAndIsVisibleInState proves
// Node.RecordRunningProfile (002-cluster-model-scheduler T016) genuinely
// submits a real CommandRecordRunningProfile Raft log entry - not merely a
// local in-memory mutation - and that the resulting reservation is visible
// via State().RunningProfiles, exactly matching fsm.go's own
// CommandRecordRunningProfile re-validation semantics (FR-005/SC-004's
// TOCTOU-closing mechanism).
func TestRecordRunningProfile_ReservesRealCapacityAndIsVisibleInState(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	node, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForLeader(t, node, 3*time.Second)

	// Seed node-a's own ClusterState.Nodes entry (RecordRunningProfile's
	// Apply refuses an unknown node - errRecordRunningProfileUnknownNode)
	// with a fixed capacity, matching the existing self-join seeding
	// pattern node_test.go's TestLeave_RemovesRealClusterStateNodesEntry
	// already establishes for this same "seed my own membership entry
	// directly via Apply" need.
	selfEntry := cluster.Node{
		ID: "node-a", Addr: node.Addr(), Health: "healthy",
		Resources: cluster.Resources{RAMAvailMB: 1000, VRAMAvailMB: 500, CPUCores: 2, NetworkMbps: 100},
	}
	seedCmd := Command{Type: CommandJoinNode, Node: &selfEntry}
	data, err := json.Marshal(seedCmd)
	if err != nil {
		t.Fatalf("json.Marshal seed: %v", err)
	}
	if err := node.raft.Apply(data, 3*time.Second).Error(); err != nil {
		t.Fatalf("seed self-join Apply: %v", err)
	}

	footprint := cluster.PlacementRequest{RAMMB: 500, VRAMMB: 250, CPUCores: 1, NetworkMbps: 50}
	if err := node.RecordRunningProfile("small", "tenant-a", "node-a", footprint); err != nil {
		t.Fatalf("RecordRunningProfile: %v", err)
	}

	state := node.State()
	if len(state.RunningProfiles) != 1 {
		t.Fatalf("RunningProfiles = %+v, want exactly 1 entry", state.RunningProfiles)
	}
	got := state.RunningProfiles[0]
	if got.Profile != "small" || got.TenantID != "tenant-a" || got.NodeID != "node-a" || got.Footprint != footprint {
		t.Fatalf("RunningProfiles[0] = %+v, want profile=small tenant=tenant-a node=node-a footprint=%+v", got, footprint)
	}
}

// TestRecordRunningProfile_RefusesWithErrInsufficientCapacityWhenOvercommitted
// proves RecordRunningProfile surfaces fsm.go's own capacity re-validation
// as a distinctly checkable error (errors.Is(err, ErrInsufficientCapacity))
// - the exact signal T016's retry-once-against-fresh-state logic needs to
// distinguish "the reservation lost a race, re-place" from "something is
// genuinely broken".
func TestRecordRunningProfile_RefusesWithErrInsufficientCapacityWhenOvercommitted(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	node, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForLeader(t, node, 3*time.Second)

	selfEntry := cluster.Node{
		ID: "node-a", Addr: node.Addr(), Health: "healthy",
		Resources: cluster.Resources{RAMAvailMB: 1000, VRAMAvailMB: 500, CPUCores: 2, NetworkMbps: 100},
	}
	seedCmd := Command{Type: CommandJoinNode, Node: &selfEntry}
	data, err := json.Marshal(seedCmd)
	if err != nil {
		t.Fatalf("json.Marshal seed: %v", err)
	}
	if err := node.raft.Apply(data, 3*time.Second).Error(); err != nil {
		t.Fatalf("seed self-join Apply: %v", err)
	}

	// First reservation consumes all 1000MB of RAM headroom.
	if err := node.RecordRunningProfile("first", "tenant-a", "node-a", cluster.PlacementRequest{RAMMB: 1000, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}); err != nil {
		t.Fatalf("first RecordRunningProfile: %v", err)
	}

	// A second reservation on the same, now-fully-committed node must be
	// refused with ErrInsufficientCapacity - the node's TOTAL capacity
	// (Resources.RAMAvailMB) never changed, only what fsm.go re-derives
	// as CURRENTLY uncommitted from the already-applied first reservation.
	err = node.RecordRunningProfile("second", "tenant-a", "node-a", cluster.PlacementRequest{RAMMB: 1, VRAMMB: 0, CPUCores: 0, NetworkMbps: 0})
	if !errors.Is(err, ErrInsufficientCapacity) {
		t.Fatalf("second RecordRunningProfile error = %v, want errors.Is(err, ErrInsufficientCapacity)", err)
	}
}

// TestClearRunningProfile_RemovesEntryIdempotently proves ClearRunningProfile
// (T017's compensating-action primitive) genuinely removes a previously
// recorded RunningProfile entry via a real Raft log entry, and that
// clearing an already-absent entry is a safe idempotent no-op - mirroring
// fsm.go's CommandClearRunningProfile handling and CommandReleaseLock's
// established idempotent-release pattern exactly.
func TestClearRunningProfile_RemovesEntryIdempotently(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	node, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForLeader(t, node, 3*time.Second)

	selfEntry := cluster.Node{
		ID: "node-a", Addr: node.Addr(), Health: "healthy",
		Resources: cluster.Resources{RAMAvailMB: 1000, VRAMAvailMB: 500, CPUCores: 2, NetworkMbps: 100},
	}
	seedCmd := Command{Type: CommandJoinNode, Node: &selfEntry}
	data, err := json.Marshal(seedCmd)
	if err != nil {
		t.Fatalf("json.Marshal seed: %v", err)
	}
	if err := node.raft.Apply(data, 3*time.Second).Error(); err != nil {
		t.Fatalf("seed self-join Apply: %v", err)
	}

	footprint := cluster.PlacementRequest{RAMMB: 500, VRAMMB: 250, CPUCores: 1, NetworkMbps: 50}
	if err := node.RecordRunningProfile("small", "tenant-a", "node-a", footprint); err != nil {
		t.Fatalf("RecordRunningProfile: %v", err)
	}
	if len(node.State().RunningProfiles) != 1 {
		t.Fatalf("RunningProfiles before clear = %+v, want 1 entry", node.State().RunningProfiles)
	}

	if err := node.ClearRunningProfile("small", "tenant-a", "node-a"); err != nil {
		t.Fatalf("first ClearRunningProfile: %v", err)
	}
	if got := node.State().RunningProfiles; len(got) != 0 {
		t.Fatalf("RunningProfiles after clear = %+v, want empty", got)
	}

	// Idempotent: clearing again (already absent) must not error.
	if err := node.ClearRunningProfile("small", "tenant-a", "node-a"); err != nil {
		t.Fatalf("second (idempotent) ClearRunningProfile: %v", err)
	}
}
