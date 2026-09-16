package cluster

import "testing"

func TestClone_IsIndependentCopy(t *testing.T) {
	original := NewClusterState()
	original.Nodes["n1"] = Node{ID: "n1", Addr: "10.0.0.1:9443", Health: "healthy"}

	clone := original.Clone()
	clone.Nodes["n1"] = Node{ID: "n1", Addr: "10.0.0.1:9443", Health: "unhealthy"}
	clone.Nodes["n2"] = Node{ID: "n2", Addr: "10.0.0.2:9443", Health: "healthy"}

	if got := original.Nodes["n1"].Health; got != "healthy" {
		t.Fatalf("mutating the clone must not affect the original: original n1.Health = %q, want %q", got, "healthy")
	}
	if _, present := original.Nodes["n2"]; present {
		t.Fatalf("adding a node to the clone must not affect the original")
	}
	if len(clone.Nodes) != 2 {
		t.Fatalf("clone should have 2 nodes, got %d", len(clone.Nodes))
	}
}

func TestNewClusterState_StartsEmpty(t *testing.T) {
	s := NewClusterState()
	if s.Nodes == nil {
		t.Fatalf("NewClusterState must initialize a non-nil Nodes map")
	}
	if len(s.Nodes) != 0 {
		t.Fatalf("a freshly constructed ClusterState must have zero nodes, got %d", len(s.Nodes))
	}
	if s.ReplicationRoles == nil {
		t.Fatalf("NewClusterState must initialize a non-nil ReplicationRoles map (003-kv-cache-replication)")
	}
	if len(s.ReplicationRoles) != 0 {
		t.Fatalf("a freshly constructed ClusterState must have zero replication roles, got %d", len(s.ReplicationRoles))
	}
}

// TestClone_ReplicationRolesIsIndependentCopy proves ReplicationRoles
// (003-kv-cache-replication) gets the SAME deep-copy guarantee Nodes/Locks
// already have (Clone's own doc comment) - a caller mutating a clone's
// role or its ReplicaNodeIDs slice must never affect the original.
func TestClone_ReplicationRolesIsIndependentCopy(t *testing.T) {
	original := NewClusterState()
	original.ReplicationRoles[""] = ReplicationRole{TenantID: "", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b"}}

	clone := original.Clone()
	clone.ReplicationRoles[""] = ReplicationRole{TenantID: "", PrimaryNodeID: "node-c", ReplicaNodeIDs: []string{"node-d"}}
	clone.ReplicationRoles[""].ReplicaNodeIDs[0] = "mutated"

	if got := original.ReplicationRoles[""].PrimaryNodeID; got != "node-a" {
		t.Fatalf("mutating the clone's role must not affect the original: original PrimaryNodeID = %q, want node-a", got)
	}
	if got := original.ReplicationRoles[""].ReplicaNodeIDs[0]; got != "node-b" {
		t.Fatalf("mutating the clone's ReplicaNodeIDs slice must not affect the original: got %q, want node-b", got)
	}
}
