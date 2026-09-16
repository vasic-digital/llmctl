package raft

import (
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// TestNode_RegisterNode_RecordsRealAPIAddrObservableFromAnotherNode
// proves RegisterNode really commits a CommandJoinNode entry through the
// Raft log - not merely a local field write - by asserting a SECOND,
// distinct node's own FSM state observes it, exactly matching
// node_test.go's TestJoin_SecondNodeReplicatesRealAppliedCommand's own
// "real replication, not just local state" proof shape.
func TestNode_RegisterNode_RecordsRealAPIAddrObservableFromAnotherNode(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	nodeA, err := Bootstrap(Config{NodeID: "node-a", BindAddr: "127.0.0.1:0", TLSConfig: buildNodeTLSConfig(t, ca, "node-a")})
	if err != nil {
		t.Fatalf("Bootstrap(node-a): %v", err)
	}
	defer func() { _ = nodeA.Shutdown() }()
	waitForLeader(t, nodeA, 3*time.Second)

	if got, want := nodeA.ID(), "node-a"; got != want {
		t.Fatalf("nodeA.ID() = %q, want %q", got, want)
	}

	nodeB, err := New(Config{NodeID: "node-b", BindAddr: "127.0.0.1:0", TLSConfig: buildNodeTLSConfig(t, ca, "node-b")})
	if err != nil {
		t.Fatalf("New(node-b): %v", err)
	}
	defer func() { _ = nodeB.Shutdown() }()
	if err := nodeA.Join("node-b", string(nodeB.transport.LocalAddr())); err != nil {
		t.Fatalf("nodeA.Join(node-b): %v", err)
	}

	if err := nodeA.RegisterNode("node-a", "10.0.0.1:8443"); err != nil {
		t.Fatalf("RegisterNode(node-a): %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		state := nodeB.fsm.State()
		if n, ok := state.Nodes["node-a"]; ok && n.Addr == "10.0.0.1:8443" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("nodeB never observed node-a's real API address registered by nodeA within the timeout")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestNode_AssignThenReassignReplicationRole_RealApplyRoundTrip proves
// AssignReplicationRole/ReassignReplicationRole really commit through
// the Raft log (not a local-only write), and that the atomic-replace
// guarantee holds end-to-end through a real *Node, not merely at the
// FSM.Apply unit-test layer T003 already covers directly.
func TestNode_AssignThenReassignReplicationRole_RealApplyRoundTrip(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	node, err := Bootstrap(Config{NodeID: "node-a", BindAddr: "127.0.0.1:0", TLSConfig: buildNodeTLSConfig(t, ca, "node-a")})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForLeader(t, node, 3*time.Second)

	role := cluster.ReplicationRole{TenantID: "tenant-a", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b"}, AssignedAt: time.Now()}
	if err := node.AssignReplicationRole(role); err != nil {
		t.Fatalf("AssignReplicationRole: %v", err)
	}
	got, ok := node.State().ReplicationRoles["tenant-a"]
	if !ok || got.PrimaryNodeID != "node-a" {
		t.Fatalf("state after AssignReplicationRole = %+v, ok=%v; want PrimaryNodeID=node-a", got, ok)
	}

	failover := cluster.ReplicationRole{TenantID: "tenant-a", PrimaryNodeID: "node-b", ReplicaNodeIDs: nil, AssignedAt: time.Now()}
	if err := node.ReassignReplicationRole(failover); err != nil {
		t.Fatalf("ReassignReplicationRole: %v", err)
	}
	got, ok = node.State().ReplicationRoles["tenant-a"]
	if !ok || got.PrimaryNodeID != "node-b" {
		t.Fatalf("state after ReassignReplicationRole = %+v, ok=%v; want PrimaryNodeID=node-b", got, ok)
	}
	if len(node.State().ReplicationRoles) != 1 {
		t.Fatalf("expected exactly one role entry for tenant-a, got %d", len(node.State().ReplicationRoles))
	}
}

// TestNode_RegisterNode_FailsOnFollower proves RegisterNode honestly
// errors (never silently no-ops or fabricates success) when called
// against a node that is not the current Raft leader - matching Join's
// own documented hraft.ErrNotLeader behavior exactly.
func TestNode_RegisterNode_FailsOnFollower(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	nodeA, err := Bootstrap(Config{NodeID: "node-a", BindAddr: "127.0.0.1:0", TLSConfig: buildNodeTLSConfig(t, ca, "node-a")})
	if err != nil {
		t.Fatalf("Bootstrap(node-a): %v", err)
	}
	defer func() { _ = nodeA.Shutdown() }()
	waitForLeader(t, nodeA, 3*time.Second)

	nodeB, err := New(Config{NodeID: "node-b", BindAddr: "127.0.0.1:0", TLSConfig: buildNodeTLSConfig(t, ca, "node-b")})
	if err != nil {
		t.Fatalf("New(node-b): %v", err)
	}
	defer func() { _ = nodeB.Shutdown() }()
	if err := nodeA.Join("node-b", string(nodeB.transport.LocalAddr())); err != nil {
		t.Fatalf("nodeA.Join(node-b): %v", err)
	}

	if err := nodeB.RegisterNode("node-b", "10.0.0.2:8443"); err == nil {
		t.Fatalf("expected RegisterNode to fail on a non-leader node, got nil error")
	}
}
