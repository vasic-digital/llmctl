package raft

import (
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// TestRegisterSelf_PopulatesOwnNodeEntryWithAPIAddrAndResources proves
// RegisterSelf (002-cluster-model-scheduler T017's prerequisite: cross-node
// forwarding needs a real APIAddr to dial, and a bootstrap leader was
// otherwise NEVER present in its own ClusterState.Nodes at all - a real,
// previously-undiscovered gap found while designing Phase 3's
// auto-placement candidate list, which reads State().Nodes directly) makes
// a freshly-bootstrapped leader appear as its own real ClusterState.Nodes
// candidate, carrying the real apiAddr and resources given.
func TestRegisterSelf_PopulatesOwnNodeEntryWithAPIAddrAndResources(t *testing.T) {
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

	// BEFORE RegisterSelf, the bootstrap leader is genuinely absent from
	// its own ClusterState.Nodes - the real gap this method closes.
	if _, ok := node.State().Nodes["node-a"]; ok {
		t.Fatalf("node-a already present in ClusterState.Nodes before RegisterSelf was ever called - test assumption violated")
	}

	resources := cluster.Resources{CPUCores: 8, RAMTotalMB: 16384, RAMAvailMB: 12000, VRAMTotalMB: 4096, VRAMAvailMB: 4096, NetworkMbps: 1000}
	if err := node.RegisterSelf("127.0.0.1:9999", resources); err != nil {
		t.Fatalf("RegisterSelf: %v", err)
	}

	got, ok := node.State().Nodes["node-a"]
	if !ok {
		t.Fatalf("node-a still absent from ClusterState.Nodes after RegisterSelf")
	}
	if got.APIAddr != "127.0.0.1:9999" {
		t.Fatalf("got.APIAddr = %q, want %q", got.APIAddr, "127.0.0.1:9999")
	}
	if got.Resources != resources {
		t.Fatalf("got.Resources = %+v, want %+v", got.Resources, resources)
	}
	if got.Health != "healthy" {
		t.Fatalf("got.Health = %q, want %q", got.Health, "healthy")
	}
	if got.ID != "node-a" || got.Addr != node.Addr() {
		t.Fatalf("got.ID/Addr = %q/%q, want %q/%q", got.ID, got.Addr, "node-a", node.Addr())
	}
}

// TestJoin_PopulatesAPIAddrAlongsideResources proves Join's own
// CommandJoinNode entry carries the joining peer's real apiAddr (the
// cross-node-forwarding dial target), not merely its Resources - the exact
// missing field that made T017's forwarding impossible for a JOINED peer,
// symmetric to RegisterSelf's fix for the bootstrap leader itself.
func TestJoin_PopulatesAPIAddrAlongsideResources(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	nodeA, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap(node-a): %v", err)
	}
	defer func() { _ = nodeA.Shutdown() }()
	waitForLeader(t, nodeA, 3*time.Second)

	nodeB, err := New(Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("New(node-b): %v", err)
	}
	defer func() { _ = nodeB.Shutdown() }()

	resources := cluster.Resources{CPUCores: 4, RAMTotalMB: 8192, RAMAvailMB: 6000}
	if err := nodeA.Join("node-b", nodeB.Addr(), "127.0.0.1:8888", resources); err != nil {
		t.Fatalf("nodeA.Join(node-b): %v", err)
	}

	got, ok := nodeA.State().Nodes["node-b"]
	if !ok {
		t.Fatalf("node-b missing from ClusterState.Nodes after Join")
	}
	if got.APIAddr != "127.0.0.1:8888" {
		t.Fatalf("got.APIAddr = %q, want %q", got.APIAddr, "127.0.0.1:8888")
	}
	if got.Resources != resources {
		t.Fatalf("got.Resources = %+v, want %+v", got.Resources, resources)
	}
}
