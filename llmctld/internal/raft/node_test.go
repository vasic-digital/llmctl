package raft

import (
	"encoding/json"
	"testing"
	"time"

	hraft "github.com/hashicorp/raft"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// waitForLeader polls n's Raft state until it becomes Leader or the timeout
// elapses - LeaderCh alone is not reliable here because a single-node
// bootstrap can elect before the test ever reaches the channel receive.
func waitForLeader(t *testing.T, n *Node, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if n.raft.State() == hraft.Leader {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("node %q never became leader within %s (state=%s)", n.localID, timeout, n.raft.State())
}

// TestBootstrap_SingleNodeBecomesLeaderQuickly proves Bootstrap really wires
// fsm.go + an in-memory store + transport.go into a functioning single-node
// Raft cluster that elects itself leader - not merely constructs values
// that compile.
func TestBootstrap_SingleNodeBecomesLeaderQuickly(t *testing.T) {
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
}

// TestJoin_SecondNodeReplicatesRealAppliedCommand proves Join does not
// merely add a membership record: after A.Join(B's address), a real
// command Applied on A's Raft log is REPLICATED and observable in B's own
// ClusterFSM state - the actual property T050/FR-019 requires ("wiring
// fsm.go + store.go + transport.go together"), not just a config change.
func TestJoin_SecondNodeReplicatesRealAppliedCommand(t *testing.T) {
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

	peerAddr := string(nodeB.transport.LocalAddr())
	if err := nodeA.Join("node-b", peerAddr, "", cluster.Resources{}); err != nil {
		t.Fatalf("nodeA.Join(%q, %q): %v", "node-b", peerAddr, err)
	}

	cmd := Command{Type: CommandJoinNode, Node: &clusterNodeFixture}
	data, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := nodeA.raft.Apply(data, 3*time.Second).Error(); err != nil {
		t.Fatalf("nodeA.raft.Apply: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		state := nodeB.fsm.State()
		if _, ok := state.Nodes[clusterNodeFixture.ID]; ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("nodeB's FSM never observed the command Applied on nodeA within the timeout - replication did not happen")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestLeave_LeaderRemovesItselfFromConfiguration proves Leave really drives
// a Raft membership change (RemoveServer), observable from the surviving
// peer's own configuration - not merely a local field flip.
func TestLeave_LeaderRemovesItselfFromConfiguration(t *testing.T) {
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

	peerAddr := string(nodeB.transport.LocalAddr())
	if err := nodeA.Join("node-b", peerAddr, "", cluster.Resources{}); err != nil {
		t.Fatalf("nodeA.Join(%q, %q): %v", "node-b", peerAddr, err)
	}

	// Wait for B to actually see itself in the replicated configuration
	// before leaving A - otherwise the later "A is gone" check would pass
	// vacuously (B never had a 2-member configuration to shrink).
	deadline := time.Now().Add(3 * time.Second)
	for {
		cfg := nodeB.raft.GetConfiguration().Configuration()
		if len(cfg.Servers) == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("nodeB never observed the 2-member configuration after Join")
		}
		time.Sleep(10 * time.Millisecond)
	}

	if err := nodeA.Leave(); err != nil {
		t.Fatalf("nodeA.Leave(): %v", err)
	}

	deadline = time.Now().Add(3 * time.Second)
	for {
		cfg := nodeB.raft.GetConfiguration().Configuration()
		found := false
		for _, srv := range cfg.Servers {
			if srv.ID == hraft.ServerID("node-a") {
				found = true
			}
		}
		if !found {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("nodeB's configuration still lists node-a after nodeA.Leave()")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestLeaderCh_ReceivesTrueOnElection proves LeaderCh() is wired to the
// real underlying hraft.Raft channel, not a stub.
func TestLeaderCh_ReceivesTrueOnElection(t *testing.T) {
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

	select {
	case isLeader := <-node.LeaderCh():
		if !isLeader {
			t.Fatalf("LeaderCh() delivered false, want true for a freshly bootstrapped single-node cluster")
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("LeaderCh() never delivered a value within 3s")
	}
}

var clusterNodeFixture = cluster.Node{ID: "fixture-node", Addr: "10.0.0.9:9000", Health: "healthy"}

// TestJoin_SurvivingFollowerBecomesLeaderAfterOriginalLeaderShutsDown is
// the PERMANENT regression guard for a real bug found via T054's
// end-to-end failover integration test: Join used to derive the joining
// peer's hraft.ServerID from its ADDRESS, but a node's own
// raft.Config.LocalID is its human-assigned NodeID - the mismatch meant
// hashicorp/raft's own "do I have a vote in the stable configuration?"
// check (hasVote(configurations.latest, r.localID) in raft.go's
// heartbeat-timeout logic) always failed for a joined follower, so it
// could NEVER start an election, invisible until the original leader
// actually died. This test reproduces the exact failure condition
// (leader gone, a follower must elect itself) at the package level -
// cheaper and faster than the full OS-process integration test in
// test/integration/, so this defect class is caught immediately by
// `go test ./internal/raft/...` rather than only by the slower
// integration suite.
//
// Uses THREE nodes, not two: a 2-node cluster has ZERO fault tolerance by
// Raft's own quorum math (majority-of-2 == 2, so losing EITHER node halts
// the cluster - this is correct Raft behavior, not the bug under test,
// confirmed by first reproducing it with 2 nodes and observing the
// EXPECTED "votes needed=2" deadlock before writing this 3-node version).
// With 3 nodes, majority-of-3 == 2, so the two survivors can still elect
// a leader after the original leader shuts down - exactly the property
// the real end-to-end integration test proved.
func TestJoin_SurvivingFollowerBecomesLeaderAfterOriginalLeaderShutsDown(t *testing.T) {
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
		t.Fatalf("Bootstrap(node-a): %v", err)
	}
	waitForLeader(t, leader, 3*time.Second)

	followerB, err := New(Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("New(node-b): %v", err)
	}
	defer func() { _ = followerB.Shutdown() }()
	if err := leader.Join("node-b", followerB.Addr(), "", cluster.Resources{}); err != nil {
		t.Fatalf("Join(node-b): %v", err)
	}

	followerC, err := New(Config{
		NodeID:    "node-c",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-c"),
	})
	if err != nil {
		t.Fatalf("New(node-c): %v", err)
	}
	defer func() { _ = followerC.Shutdown() }()
	if err := leader.Join("node-c", followerC.Addr(), "", cluster.Resources{}); err != nil {
		t.Fatalf("Join(node-c): %v", err)
	}

	// Wait for BOTH followers to durably observe the full 3-member
	// configuration BEFORE killing the leader - matching the real
	// precondition-timing lesson the integration test's own fix
	// documents (a leader's local view of its configuration is not proof
	// the change has propagated to followers yet).
	deadline := time.Now().Add(3 * time.Second)
	for _, f := range []*Node{followerB, followerC} {
		for {
			servers, err := f.Servers()
			if err == nil && len(servers) == 3 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("a follower never observed the 3-member configuration after both joins")
			}
			time.Sleep(10 * time.Millisecond)
		}
	}

	if err := leader.Shutdown(); err != nil {
		t.Fatalf("leader.Shutdown(): %v", err)
	}

	deadline = time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if followerB.raft.State() == hraft.Leader || followerC.raft.State() == hraft.Leader {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("neither surviving follower became leader within 10s of the original leader shutting down")
}

// TestJoin_PopulatesRealClusterStateNodesEntry is T004's RED-then-GREEN
// test: it asserts that AFTER a real Join call on a real bootstrapped
// node, node.State().Nodes[peerID] is genuinely present with the exact
// resources passed in - proving Join reaches the FSM via a real
// CommandJoinNode Apply, not merely hashicorp/raft's own AddVoter
// membership-only change. This FAILS against the pre-T004 Join (which
// never called n.raft.Apply at all, so ClusterState.Nodes stayed empty
// forever regardless of how many peers had joined).
func TestJoin_PopulatesRealClusterStateNodesEntry(t *testing.T) {
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

	peerAddr := string(nodeB.transport.LocalAddr())
	wantResources := cluster.Resources{CPUCores: 8, RAMTotalMB: 16384, RAMAvailMB: 12000, VRAMTotalMB: 4096, VRAMAvailMB: 4096, NetworkMbps: 1000}
	if err := nodeA.Join("node-b", peerAddr, "", wantResources); err != nil {
		t.Fatalf("nodeA.Join(%q, %q, resources): %v", "node-b", peerAddr, err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		state := nodeA.State()
		if n, ok := state.Nodes["node-b"]; ok {
			if n.Resources != wantResources {
				t.Fatalf("node-b's Resources = %+v, want %+v", n.Resources, wantResources)
			}
			if n.Addr != peerAddr {
				t.Fatalf("node-b's Addr = %q, want %q", n.Addr, peerAddr)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("nodeA.State().Nodes never contained node-b within the timeout - Join did not reach the FSM")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestLeave_RemovesRealClusterStateNodesEntry is T005's RED-then-GREEN
// test: given a leader whose OWN FSM already carries a ClusterState.Nodes
// entry for itself (seeded the same way T004's Join seeds a peer's entry -
// a real Apply'd CommandJoinNode), a real Leave() call on that leader
// (removing itself, matching Leave's own doc-comment contract and the
// pre-existing TestLeave_LeaderRemovesItselfFromConfiguration's calling
// pattern) MUST remove that exact FSM entry too - proving Leave reaches
// the FSM via a real CommandLeaveNode Apply, not merely hashicorp/raft's
// own RemoveServer membership-only change. This FAILS against the
// pre-T005 Leave (which never called n.raft.Apply at all, so the entry
// stayed in ClusterState.Nodes forever).
func TestLeave_RemovesRealClusterStateNodesEntry(t *testing.T) {
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

	// A second voter is required so nodeA removing ITSELF (below) leaves a
	// live quorum-of-one behind - matching the pre-existing
	// TestLeave_LeaderRemovesItselfFromConfiguration's identical setup,
	// and avoiding the degenerate single-voter-removes-itself edge case
	// this test is not about.
	nodeB, err := New(Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("New(node-b): %v", err)
	}
	defer func() { _ = nodeB.Shutdown() }()
	if err := nodeA.Join("node-b", string(nodeB.transport.LocalAddr()), "", cluster.Resources{}); err != nil {
		t.Fatalf("nodeA.Join(node-b): %v", err)
	}

	selfEntry := cluster.Node{ID: "node-a", Addr: nodeA.Addr(), Health: "healthy"}
	cmd := Command{Type: CommandJoinNode, Node: &selfEntry}
	data, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if err := nodeA.raft.Apply(data, 3*time.Second).Error(); err != nil {
		t.Fatalf("seed self-join Apply: %v", err)
	}
	if _, ok := nodeA.State().Nodes["node-a"]; !ok {
		t.Fatalf("seed self-join did not populate ClusterState.Nodes[node-a]")
	}

	if err := nodeA.Leave(); err != nil {
		t.Fatalf("nodeA.Leave(): %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, ok := nodeA.State().Nodes["node-a"]; !ok {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("nodeA.State().Nodes still contains node-a after it left")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
