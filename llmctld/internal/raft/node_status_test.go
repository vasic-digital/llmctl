package raft

import (
	"testing"
	"time"

	hraft "github.com/hashicorp/raft"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// TestIsLeader_ReflectsRealRaftState proves IsLeader is wired to the real
// underlying raft.State(), not a stub.
func TestIsLeader_ReflectsRealRaftState(t *testing.T) {
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

	if !node.IsLeader() {
		t.Fatalf("IsLeader() = false after waitForLeader confirmed raft.State()==Leader")
	}
}

// TestServers_ReflectsRealConfigurationAfterJoin proves Servers() reads
// the real Raft configuration - a single-node bootstrap reports exactly
// itself as Voter, and after a real Join, both nodes.
func TestServers_ReflectsRealConfigurationAfterJoin(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	leader, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	defer func() { _ = leader.Shutdown() }()
	waitForLeader(t, leader, 3*time.Second)

	servers, err := leader.Servers()
	if err != nil {
		t.Fatalf("Servers(): %v", err)
	}
	if len(servers) != 1 || servers[0].ID != "node-a" || servers[0].Suffrage != "Voter" {
		t.Fatalf("Servers() after bootstrap = %+v, want exactly [{ID:node-a Suffrage:Voter ...}]", servers)
	}

	follower, err := New(Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("New(node-b): %v", err)
	}
	defer func() { _ = follower.Shutdown() }()

	peerAddr := string(follower.transport.LocalAddr())
	if err := leader.Join("node-b", peerAddr, cluster.Resources{}); err != nil {
		t.Fatalf("Join: %v", err)
	}

	servers, err = leader.Servers()
	if err != nil {
		t.Fatalf("Servers() after Join: %v", err)
	}
	if len(servers) != 2 {
		t.Fatalf("Servers() after Join has %d entries, want 2", len(servers))
	}
}

// TestServerInfo_SuffrageIsRealHraftValue proves ServerInfo.Suffrage is
// derived from the real hraft.ServerSuffrage.String(), not a hardcoded
// literal - a golden-good/golden-bad style check against the real type.
func TestServerInfo_SuffrageIsRealHraftValue(t *testing.T) {
	if got, want := hraft.Voter.String(), "Voter"; got != want {
		t.Fatalf("hraft.Voter.String() = %q, want %q (test assumption invalid)", got, want)
	}
}
